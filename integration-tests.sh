#!/bin/bash -ex

NEXUS_VERSION="${1:-3.16.2}"
NEXUS_API_VERSION="${2:-v1}"
TOOL="${3:-./n3dr}"

validate(){
    if [ -z "$TOOL" ]; then
        echo "No deliverable defined. Assuming that 'go run main.go' 
should be run."
        TOOL="go run main.go"
    fi

    if [ -z "$NEXUS_VERSION" ] || [ -z "$NEXUS_API_VERSION" ]; then
        echo "NEXUS_VERSION and NEXUS_API_VERSION should be specified."
        exit 1
    fi
}

nexus(){
    docker run --rm -d -p 9999:8081 --name nexus sonatype/nexus3:${NEXUS_VERSION}
}

readiness(){
    until docker logs nexus | grep 'Started Sonatype Nexus OSS'
    do
        echo "Nexus unavailable"
        sleep 10
    done
}

# Since nexus 3.17.0 the default 'admin123' was changed by an autogenerated
# one. This function retrieves the autogenerated password and if this file
# is unavailable, the default 'admin123' is returned.
password(){
    local pw="docker exec -it nexus cat /nexus-data/admin.password"
    if $pw; then
        export PASSWORD=$(exec ${pw})
    else
        export PASSWORD="admin123"
    fi
}

artifact(){
    mkdir -p maven-releases/file${1}/file${1}/1.0.0
    echo someContent > maven-releases/file${1}/file${1}/1.0.0/file${1}-1.0.0.jar
    echo -e "<project>\n<modelVersion>4.0.0</modelVersion>\n<groupId>file${1}</groupId>\n<artifactId>file${1}</artifactId>\n<version>1.0.0</version>\n</project>" > maven-releases/file${1}/file${1}/1.0.0/file${1}-1.0.0.pom   
}

files(){
    for a in $(seq 10); do artifact ${a}; done
}

upload(){
    echo "Testing upload..."
    $TOOL upload -u admin -p $PASSWORD -r maven-releases -n http://localhost:9999 -v ${NEXUS_API_VERSION}
    echo
}

backup(){
    echo "Testing backup..."
    $TOOL backup -n http://localhost:9999 -u admin -p $PASSWORD -r maven-releases -v ${NEXUS_API_VERSION}
    $TOOL backup -n http://localhost:9999 -u admin -p $PASSWORD -r maven-releases -v ${NEXUS_API_VERSION} -z

    if [ "${NEXUS_VERSION}" == "3.9.0" ]; then
        count_downloads 20
        test_zip 12
    else
        count_downloads 30
        test_zip 16
    fi

    cleanup_downloads
}

repositories(){
    echo "Testing repositories..."
    $TOOL repositories -n http://localhost:9999 -u admin -p $PASSWORD -v ${NEXUS_API_VERSION} -a | grep maven-releases
    $TOOL repositories -n http://localhost:9999 -u admin -p $PASSWORD -v ${NEXUS_API_VERSION} -c | grep 7
    $TOOL repositories -n http://localhost:9999 -u admin -p $PASSWORD -v ${NEXUS_API_VERSION} -b
    $TOOL repositories -n http://localhost:9999 -u admin -p $PASSWORD -v ${NEXUS_API_VERSION} -b -z

    if [ "${NEXUS_VERSION}" == "3.9.0" ]; then
        count_downloads 40
        test_zip 24
    else
        count_downloads 60
        test_zip 32
    fi

    cleanup_downloads
}

cleanup(){
    cleanup_downloads
    docker stop nexus
}

count_downloads(){
    local actual=$(find download -type f | wc -l)
    echo "Expected: ${1}"
    echo "Actual: ${actual}"
    echo $actual | grep $1
}

test_zip(){
    local size=$(du n3dr-backup-*zip)
    echo "Actual: ${size}"
    echo "Expected: ${1}"
    echo $size | grep "^${1}"
}

cleanup_downloads(){
    rm -rf maven-releases
    rm -f n3dr-backup-*zip
    rm -rf download
}

main(){
    validate
    nexus
    readiness
    password
    files
    upload
    backup
    repositories
    bats --tap tests.bats
}

trap cleanup EXIT
main