#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        if rlIsRHEL 8 || rlIsCentOS 8; then
            # need to use pip version of packaging module due to a bug causing test failure
            # File "/usr/local/lib/python3.6/site-packages/keylime-6.3.1-py3.6.egg/keylime/api_version.py", line 26, in latest_minor_version
            #   major_v = str(v_obj.major)
            #   AttributeError: 'Version' object has no attribute 'major'
            rlLogInfo "I have to remove python3-packaging as it is old and doesn't work well with tests"
            rlRun "rpm -e python3-packaging"
            rlRun "pip3 install packaging"
        fi

        # backup keylime
        rlRun "rlFileBackup --missing-ok /var/lib/keylime"
        limeBackupConfig
        # update keylime configuration
        rlRun "limeUpdateConf general tls_check_hostnames True"
        rlRun "limeUpdateConf cloud_agent run_as root:root"
        # need to adjust file permissions since we are running keylime as root (for now)
        rlRun "rm -f /var/log/keylime/*"
        rlRun "chown -R root.root /var/lib/keylime"
        # install required python modules
        rlRun "pip3 install pytest-asyncio pyaml"
        # download the test suite
        rlAssertExists /var/tmp/keylime_sources/test
        rlRun "TmpDir=\$( mktemp -d )"
        rlRun "cp -r /var/tmp/keylime_sources/test $TmpDir"
        pushd $TmpDir/test
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
            # start ima emulator
            export TPM2TOOLS_TCTI=tabrmd:bus_name=com.intel.tss2.Tabrmd
            export TCTI=tabrmd:
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        else
            rlServiceStart tpm2-abrmd
        fi
        # prepare /var/lib/keylime/secure tmpfs if note present
        SECDIR=/var/lib/keylime/secure
        if ! mount | grep -q ${SECDIR}; then
            rlRun "mkdir -p ${SECDIR}"
            rlRun "mount -t tmpfs -o size=1024k,mode=700 tmpfs ${SECDIR}"
        fi
        sleep 5
    rlPhaseEnd

    rlPhaseStartTest "Run unit tests"
        rlRun "python3 -m unittest discover -s keylime -p '*_test.py' -v"
    rlPhaseEnd

    for TEST in `ls test_*.py`; do
        rlPhaseStartTest "Run $TEST"
            if ${__INTERNAL_limeCoverageEnabled}; then
                # update coverage context to this particular test
                rlRun "sed -i 's#context =.*#context = ${TEST}#' /var/tmp/limeLib/coverage/coveragerc"
                rlRun "/usr/local/bin/coverage run ${PWD}/${TEST}"
            else
                rlRun "python3 ${PWD}/${TEST}"
            fi
        rlPhaseEnd
    done

    rlPhaseStartCleanup "Do the keylime cleanup"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
        fi
        # move test coverage files away to preserve them
        if ${__INTERNAL_limeCoverageEnabled}; then
            ls -al .coverage*
            rlRun "coverage combine"
            rlRun "mv .coverage ${__INTERNAL_limeCoverageDir}/.coverage.testsuite"
        fi
        popd
        limeClearData
        limeRestoreConfig
        rlRun "rlFileRestore"
        rlServiceRestore tpm2-abrmd
        rlRun "rm -rf $TmpDir"
    rlPhaseEnd

rlJournalEnd