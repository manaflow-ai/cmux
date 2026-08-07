import Darwin
import Foundation
import Testing

@testable import CmuxFoundation

@Suite(.serialized)
struct SSHForegroundAuthenticationRetryPolicyTests {
    @Test func mapsBootTimeTransportFailureToRetryableStatus() throws {
        let result = try run(
            "printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func preservesPermanentAuthenticationFailure() throws {
        let result = try run(
            "printf '%s\\n' 'user@example.test: Permission denied (publickey,password).' >&2; exit 255"
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains("Permission denied"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func distinguishesUnclassifiedFailureFromPermanentFailure() throws {
        let result = try run("exit 255")

        #expect(result.status == 252)
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func preservesNonSSHFailureStatus() throws {
        let result = try run("exit 3")

        #expect(result.status == 3)
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func pinsDiagnosticLocaleForWrappedAuthenticationCommand() throws {
        let result = try run(
            """
            if [ "${LC_ALL:-}" != C ] || [ "${LANG:-}" != C ]; then exit 3; fi
            printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func permanentFailureTakesPrecedenceOverEarlierTransportDiagnostic() throws {
        let result = try run(
            """
            printf '%s\\n' 'debug1: connect to address 2001:db8::1 port 22: Network is unreachable' >&2
            printf '%s\\n' 'user@example.test: Permission denied (publickey,password).' >&2
            exit 255
            """
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(result.stderr.contains("Permission denied"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func mapsTemporaryDNSResolutionFailureToRetryableStatus() throws {
        let result = try run(
            """
            printf '%s\\n' \
              'ssh: Could not resolve hostname example.test: Temporary failure in name resolution' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Temporary failure in name resolution"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func mapsServerAliveTimeoutToRetryableStatus() throws {
        let result = try run(
            "printf '%s\\n' 'Timeout, server example.test not responding.' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Timeout, server example.test not responding."))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "Connection to 192.0.2.1 port 22 timed out",
        "Connection to example.test closed by remote host.",
        "send disconnect: Connection to 192.0.2.1 port 22: Broken pipe",
        "ssh: connect to host example.test port 22: Network is down",
        "ssh: connect to host example.test port 22: Host is down",
    ])
    func mapsStandardOpenSSHTransportDiagnosticToRetryableStatus(_ diagnostic: String) throws {
        let result = try run("printf '%s\\n' '\(diagnostic)' >&2; exit 255")

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: ["Connection refused", "Connection reset by peer"])
    func mapsDirectConnectionStartupFailureToRetryableStatus(_ diagnostic: String) throws {
        let result = try run(
            "printf '%s\\n' 'ssh: connect to host example.test port 22: \(diagnostic)' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func mapsAddressQualifiedConnectionResetToRetryableStatus() throws {
        let result = try run(
            "printf '%s\\n' 'Connection reset by 192.0.2.1 port 22' >&2; exit 255"
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Connection reset by 192.0.2.1 port 22"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "Connection closed by UNKNOWN port 65535",
        "ssh_dispatch_run_fatal: Connection to UNKNOWN port 65535: Broken pipe",
        """
        channel 0: open failed: administratively prohibited: open failed
        Connection closed by UNKNOWN port 65535
        """,
    ])
    func leavesGenericProxyTransportClosureUnclassified(_ diagnostic: String) throws {
        let result = try run("printf '%s\\n' '\(diagnostic)' >&2; exit 255")

        #expect(result.status == 252)
        for line in diagnostic.split(separator: "\n") {
            #expect(result.stderr.contains(String(line)))
        }
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func independentTransportDiagnosticMakesProxyClosureRetryable() throws {
        let result = try run(
            """
            printf '%s\\n' 'connect failed: Connection refused' >&2
            printf '%s\\n' 'Connection closed by UNKNOWN port 65535' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Connection refused"))
        #expect(result.stderr.contains("Connection closed by UNKNOWN port 65535"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "Warning: Identity file /tmp/missing-key not accessible: No such file or directory.",
        "debug1: load_hostkeys: fopen /tmp/missing-known-hosts: No such file or directory",
        "Warning: Identity file /tmp/unreadable-key not accessible: Permission denied.",
        "debug1: load_hostkeys: fopen /tmp/unreadable-known-hosts: Permission denied",
    ])
    func nonFatalMissingFileDiagnosticDoesNotOverrideTransportFailure(_ diagnostic: String) throws {
        let result = try run(
            """
            printf '%s\\n' '\(diagnostic)' >&2
            printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "kex_exchange_identification: Connection closed by remote host",
        "Connection closed by 192.0.2.1 port 22",
    ])
    func mapsConnectionClosedStartupFailureToRetryableStatus(_ diagnostic: String) throws {
        let result = try run("printf '%s\\n' '\(diagnostic)' >&2; exit 255")

        #expect(result.status == 254)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func preservesTerminalStderrForInteractiveAuthenticationHelpers() throws {
        let result = try run(
            """
            if ! test -t 2; then
              printf '%s\\n' 'authentication helper requires a terminal' >&2
              exit 255
            fi
            printf '%s\\n' 'ssh: connect to host example.test port 22: Network is unreachable' >&2
            exit 255
            """
        )

        #expect(result.status == 254)
        #expect(result.stderr.contains("Network is unreachable"))
        #expect(!result.stderr.contains("authentication helper requires a terminal"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test(arguments: [
        "zsh: command not found: corp-proxy",
        "zsh:1: no such file or directory: /opt/corp/proxy",
        "bash: line 1: /opt/corp/proxy: No such file or directory",
    ])
    func proxyConfigurationFailureTakesPrecedenceOverGenericTransportMarker(
        _ diagnostic: String
    ) throws {
        let result = try run(
            """
            printf '%s\\n' '\(diagnostic)' >&2
            printf '%s\\n' 'Connection closed by UNKNOWN port 65535' >&2
            exit 255
            """
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains(diagnostic))
        #expect(result.stderr.contains("Connection closed by UNKNOWN port 65535"))
        #expect(result.temporaryFiles.isEmpty)
    }

    @Test func terminatesNestedForegroundAuthenticationProcesses() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-tree-\(UUID().uuidString)", isDirectory: true)
        let leafScript = root.appendingPathComponent("leaf.sh")
        let leafPIDFile = root.appendingPathComponent("leaf.pid")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" > "$CMUX_TEST_LEAF_PID"
        while :; do /bin/sleep 30; done
        """.write(to: leafScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leafScript.path)

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: "/usr/bin/script -q /dev/null /bin/sh \"$CMUX_TEST_LEAF_SCRIPT\""
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        trap '/bin/kill -KILL "$cmux_test_auth_root" >/dev/null 2>&1 || true' EXIT
        cmux_test_ready_attempt=0
        while [ ! -s "$CMUX_TEST_LEAF_PID" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -s "$CMUX_TEST_LEAF_PID" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        trap - EXIT
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_LEAF_SCRIPT": leafScript.path,
            "CMUX_TEST_LEAF_PID": leafPIDFile.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let leafPID = try #require(Int32(
            String(contentsOf: leafPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(leafPID, SIGKILL) }
        let exitDeadline = Date.now.addingTimeInterval(1)
        while Darwin.kill(leafPID, 0) == 0, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(process.terminationStatus == 0)
        #expect(Darwin.kill(leafPID, 0) != 0)
    }

    @Test func cleanupFailureDoesNotLeaveStoppedAuthenticationProcesses() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-cleanup-failure-\(UUID().uuidString)", isDirectory: true)
        let leafScript = root.appendingPathComponent("leaf.sh")
        let cleanupWorkerScript = root.appendingPathComponent("cleanup-worker.sh")
        let cleanupWorkerPIDFile = root.appendingPathComponent("cleanup-worker.pid")
        let leafPIDFile = root.appendingPathComponent("leaf.pid")
        let reaperPIDFile = root.appendingPathComponent("reaper.pid")
        let observedProcessFile = root.appendingPathComponent("observed-process")
        let snapshotPermissionFile = root.appendingPathComponent("snapshot-permission")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "0\n".write(to: snapshotPermissionFile, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" > "$CMUX_TEST_LEAF_PID"
        while :; do /bin/sleep 30; done
        """.write(to: leafScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leafScript.path)

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: "/usr/bin/script -q /dev/null /bin/sh \"$CMUX_TEST_LEAF_SCRIPT\""
        )
        try """
        #!/bin/sh
        printf '%s\n' "$$" > "$CMUX_TEST_CLEANUP_WORKER_PID" || exit 99
        \(policy.processTreeTerminationShellFunction())
        cmux_ssh_auth_take_process_snapshot() {
          if [ "$(/bin/cat "$CMUX_TEST_SNAPSHOT_PERMISSION")" != 1 ]; then return 1; fi
          /usr/bin/env LC_ALL=C LANG=C /bin/ps -axo pid=,ppid=,pgid=,state=,lstart= > "$1" 2>/dev/null
        }
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        trap '/bin/kill -KILL "$cmux_test_auth_root" >/dev/null 2>&1 || true' EXIT
        cmux_test_ready_attempt=0
        while [ ! -s "$CMUX_TEST_LEAF_PID" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -s "$CMUX_TEST_LEAF_PID" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 97
        cmux_test_leaf_pid=$(/bin/cat "$CMUX_TEST_LEAF_PID") || exit 96
        /bin/kill -0 "$cmux_test_leaf_pid" >/dev/null 2>&1 || exit 95
        cmux_test_leaf_state=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o state= \
          -p "$cmux_test_leaf_pid" 2>/dev/null || true)
        case "$cmux_test_leaf_state" in *T*) exit 94 ;; esac
        cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR" || exit 93
        printf '%s\n' "$!" > "$CMUX_TEST_REAPER_PID" || exit 92
        trap - EXIT
        """.write(to: cleanupWorkerScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cleanupWorkerScript.path)

        let command = """
        /bin/zsh "$CMUX_TEST_CLEANUP_WORKER"
        cmux_test_cleanup_worker_status=$?
        if [ "$cmux_test_cleanup_worker_status" -ne 0 ]; then
          exit "$cmux_test_cleanup_worker_status"
        fi
        cmux_test_cleanup_worker_pid=$(/bin/cat "$CMUX_TEST_CLEANUP_WORKER_PID") || exit 98
        /bin/kill -0 "$cmux_test_cleanup_worker_pid" >/dev/null 2>&1 && exit 97
        test -s "$CMUX_TEST_REAPER_PID" || exit 98
        printf '%s\n' 1 > "$CMUX_TEST_SNAPSHOT_PERMISSION" || exit 93
        cmux_test_leaf_pid=$(/bin/cat "$CMUX_TEST_LEAF_PID") || exit 92
        cmux_test_reaper_pid=$(/bin/cat "$CMUX_TEST_REAPER_PID") || exit 91
        cmux_test_reaper_attempt=0
        while { /bin/kill -0 "$cmux_test_leaf_pid" >/dev/null 2>&1 || \
          [ -d "$CMUX_SSH_AUTH_GROUP_DIR" ] || \
          /bin/kill -0 "$cmux_test_reaper_pid" >/dev/null 2>&1; } && \
          [ "$cmux_test_reaper_attempt" -lt 600 ]; do
          /bin/sleep 0.01
          cmux_test_reaper_attempt=$((cmux_test_reaper_attempt + 1))
        done
        /usr/bin/env LC_ALL=C LANG=C /bin/ps -o pid=,ppid=,pgid=,state=,lstart= \
          -p "$(/bin/cat "$CMUX_TEST_LEAF_PID")" > "$CMUX_TEST_OBSERVED_PROCESS" 2>/dev/null || true
        /bin/kill -0 "$cmux_test_leaf_pid" >/dev/null 2>&1 && exit 90
        test ! -d "$CMUX_SSH_AUTH_GROUP_DIR" || exit 89
        /bin/kill -0 "$cmux_test_reaper_pid" >/dev/null 2>&1 && exit 88
        exit 0
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_LEAF_SCRIPT": leafScript.path,
            "CMUX_TEST_CLEANUP_WORKER": cleanupWorkerScript.path,
            "CMUX_TEST_CLEANUP_WORKER_PID": cleanupWorkerPIDFile.path,
            "CMUX_TEST_LEAF_PID": leafPIDFile.path,
            "CMUX_TEST_REAPER_PID": reaperPIDFile.path,
            "CMUX_TEST_OBSERVED_PROCESS": observedProcessFile.path,
            "CMUX_TEST_SNAPSHOT_PERMISSION": snapshotPermissionFile.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture, timeout: 20)

        let leafPID = try #require(Int32(
            String(contentsOf: leafPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(leafPID, SIGKILL) }
        let exitDeadline = Date.now.addingTimeInterval(1)
        while Darwin.kill(leafPID, 0) == 0, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(
            process.terminationStatus == 0,
            "Cleanup supervisor failed: \((try? String(contentsOf: stderrCapture.url, encoding: .utf8)) ?? "missing")"
        )
        #expect(
            Darwin.kill(leafPID, 0) != 0,
            "Cleanup failure left: \((try? String(contentsOf: observedProcessFile, encoding: .utf8)) ?? "missing")"
        )
        #expect(!fileManager.fileExists(atPath: groupDirectory.path))
    }

    @Test func cleanupDeadlineKillsOwnedProcessesBeforeReturning() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-cleanup-deadline-\(UUID().uuidString)", isDirectory: true)
        let leafScript = root.appendingPathComponent("leaf.sh")
        let leafPIDFile = root.appendingPathComponent("leaf.pid")
        let processStateFile = root.appendingPathComponent("leaf.state")
        let clockFile = root.appendingPathComponent("clock")
        let deadlineExpiredMarker = root.appendingPathComponent("deadline-expired")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "0\n".write(to: clockFile, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" > "$CMUX_TEST_LEAF_PID"
        while :; do /bin/sleep 30; done
        """.write(to: leafScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leafScript.path)

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: "/usr/bin/script -q /dev/null /bin/sh \"$CMUX_TEST_LEAF_SCRIPT\""
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() {
          cmux_test_now=$(/bin/cat "$CMUX_TEST_CLOCK_FILE") || return 1
          cmux_test_now=$((cmux_test_now + 150))
          printf '%s\\n' "$cmux_test_now" > "$CMUX_TEST_CLOCK_FILE" || return 1
          case "${cmux_ssh_auth_deadline_millis:-}" in
            ''|*[!0-9]*) ;;
            *)
              if [ "$cmux_test_now" -ge "$cmux_ssh_auth_deadline_millis" ]; then
                : > "$CMUX_TEST_DEADLINE_EXPIRED_MARKER" || return 1
              fi
              ;;
          esac
          printf '%s\\n' "$cmux_test_now"
        }
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        trap '/bin/kill -KILL "$cmux_test_auth_root" >/dev/null 2>&1 || true' EXIT
        cmux_test_ready_attempt=0
        while [ ! -s "$CMUX_TEST_LEAF_PID" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -s "$CMUX_TEST_LEAF_PID" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        /usr/bin/env LC_ALL=C LANG=C /bin/ps -o state= \
          -p "$(/bin/cat "$CMUX_TEST_LEAF_PID")" > "$CMUX_TEST_PROCESS_STATE" 2>/dev/null || true
        trap - EXIT
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_CLOCK_FILE": clockFile.path,
            "CMUX_TEST_DEADLINE_EXPIRED_MARKER": deadlineExpiredMarker.path,
            "CMUX_TEST_LEAF_SCRIPT": leafScript.path,
            "CMUX_TEST_LEAF_PID": leafPIDFile.path,
            "CMUX_TEST_PROCESS_STATE": processStateFile.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let leafPID = try #require(Int32(
            String(contentsOf: leafPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let leafGroup = Darwin.getpgid(leafPID)
        defer {
            if leafGroup > 0 {
                Darwin.kill(-leafGroup, SIGKILL)
            }
            Darwin.kill(leafPID, SIGKILL)
        }
        let processState = try String(contentsOf: processStateFile, encoding: .utf8)

        #expect(process.terminationStatus == 0)
        #expect(fileManager.fileExists(atPath: deadlineExpiredMarker.path))
        #expect(Darwin.kill(leafPID, 0) != 0)
        #expect(processState.isEmpty, "Deadline fallback left a process behind: \(processState)")
        #expect(!fileManager.fileExists(atPath: groupDirectory.path))
    }

    @Test func hardDeadlineFallbackRevalidatesRecordedProcessIdentity() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-deadline-identity-\(UUID().uuidString)", isDirectory: true)
        let frozenFile = root.appendingPathComponent("frozen")
        let orderedFile = root.appendingPathComponent("ordered")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
        cmux_test_victim_pid=$!
        trap '/bin/kill -KILL "$cmux_test_victim_pid" >/dev/null 2>&1 || true; wait "$cmux_test_victim_pid" 2>/dev/null || true' EXIT
        printf '%s 1 1 stale_identity S\n' "$cmux_test_victim_pid" > "$CMUX_TEST_FROZEN"
        cmux_ssh_auth_take_process_snapshot() { : > "$1"; }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_CURRENT"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        if cmux_ssh_auth_force_frozen_processes; then exit 96; fi
        /bin/kill -0 "$cmux_test_victim_pid" >/dev/null 2>&1 || exit 97
        trap - EXIT
        /bin/kill -KILL "$cmux_test_victim_pid" >/dev/null 2>&1 || true
        wait "$cmux_test_victim_pid" 2>/dev/null || true
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
            "CMUX_TEST_FROZEN": frozenFile.path,
            "CMUX_TEST_ORDERED": orderedFile.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
    }

    @Test func forceOwnedProcessesChecksDeadlineInsidePIDLoop() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-loop-deadline-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() {
          cmux_test_deadline_calls=$(/bin/cat "$CMUX_TEST_DEADLINE_CALLS") || return 1
          cmux_test_deadline_calls=$((cmux_test_deadline_calls + 1))
          printf '%s\n' "$cmux_test_deadline_calls" > "$CMUX_TEST_DEADLINE_CALLS" || return 1
          [ "$cmux_test_deadline_calls" -le 1 ]
        }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 1 2 S Thu Jan 1 00:00:00 1970\n102 1 2 S Thu Jan 1 00:00:00 1970\n103 1 2 S Thu Jan 1 00:00:00 1970\n' > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() { : > "$cmux_ssh_auth_owned_groups"; }
        cmux_ssh_auth_order_children_first() {
          /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"
        }
        printf '0\n' > "$CMUX_TEST_DEADLINE_CALLS"
        printf '101 1 2 Thu_Jan_1_00:00:00_1970 S\n102 1 2 Thu_Jan_1_00:00:00_1970 S\n103 1 2 Thu_Jan_1_00:00:00_1970 S\n' \
          > "$CMUX_TEST_OWNED"
        : > "$CMUX_TEST_GROUPS"
        cmux_ssh_auth_caller_group=3
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_groups="$CMUX_TEST_GROUPS_NEXT"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        if cmux_ssh_auth_force_owned_processes; then exit 98; fi
        test "$(/bin/cat "$CMUX_TEST_DEADLINE_CALLS")" -eq 2 || exit 97
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_TEST_DEADLINE_CALLS": root.appendingPathComponent("deadline-calls").path,
            "CMUX_TEST_GROUPS": root.appendingPathComponent("groups").path,
            "CMUX_TEST_GROUPS_NEXT": root.appendingPathComponent("groups.next").path,
            "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
            "CMUX_TEST_ORDERED": root.appendingPathComponent("ordered").path,
            "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
            "CMUX_TEST_OWNED_NEXT": root.appendingPathComponent("owned.next").path,
            "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func forceFrozenProcessGroupsChecksDeadlineInsideKillLoop(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-frozen-group-deadline-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() {
          cmux_test_deadline_calls=$(/bin/cat "$CMUX_TEST_DEADLINE_CALLS") || return 1
          cmux_test_deadline_calls=$((cmux_test_deadline_calls + 1))
          printf '%s\n' "$cmux_test_deadline_calls" > "$CMUX_TEST_DEADLINE_CALLS" || return 1
          [ "$cmux_test_deadline_calls" -le 1 ]
        }
        kill() {
          printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"
          return 0
        }
        printf '0\n' > "$CMUX_TEST_DEADLINE_CALLS"
        printf '101 1 11 Thu_Jan_1_00:00:00_1970 T\n102 1 12 Thu_Jan_1_00:00:00_1970 T\n' \
          > "$CMUX_TEST_FROZEN"
        /bin/cp "$CMUX_TEST_FROZEN" "$CMUX_TEST_OWNED" || exit 99
        printf '101 1 11 T Thu Jan 1 00:00:00 1970\n102 1 12 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_SNAPSHOT"
        printf '11\n12\n' > "$CMUX_TEST_GROUPS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        if cmux_ssh_auth_force_frozen_processes "$CMUX_TEST_SNAPSHOT"; then exit 98; fi
        test "$(/bin/cat "$CMUX_TEST_DEADLINE_CALLS")" -eq 2 || exit 97
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" -eq 1 || exit 96
        /usr/bin/grep -Fxq -- '-KILL -- -11' "$CMUX_TEST_SIGNALS" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_DEADLINE_CALLS": root.appendingPathComponent("deadline-calls").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_GROUPS": root.appendingPathComponent("groups").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
                "CMUX_TEST_OWNED_NEXT": root.appendingPathComponent("owned.next").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func forceFrozenProcessesChecksDeadlineInsidePIDKillLoop(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-frozen-pid-deadline-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() {
          cmux_test_deadline_calls=$(/bin/cat "$CMUX_TEST_DEADLINE_CALLS") || return 1
          cmux_test_deadline_calls=$((cmux_test_deadline_calls + 1))
          printf '%s\n' "$cmux_test_deadline_calls" > "$CMUX_TEST_DEADLINE_CALLS" || return 1
          [ "$cmux_test_deadline_calls" -le 1 ]
        }
        kill() {
          printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"
          return 0
        }
        printf '0\n' > "$CMUX_TEST_DEADLINE_CALLS"
        printf '101 1 11 Thu_Jan_1_00:00:00_1970 T\n102 1 12 Thu_Jan_1_00:00:00_1970 T\n' \
          > "$CMUX_TEST_FROZEN"
        /bin/cp "$CMUX_TEST_FROZEN" "$CMUX_TEST_OWNED" || exit 99
        printf '101 1 11 T Thu Jan 1 00:00:00 1970\n102 1 12 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_SNAPSHOT"
        : > "$CMUX_TEST_GROUPS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        if cmux_ssh_auth_force_frozen_processes "$CMUX_TEST_SNAPSHOT"; then exit 98; fi
        test "$(/bin/cat "$CMUX_TEST_DEADLINE_CALLS")" -eq 2 || exit 97
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" -eq 1 || exit 96
        /usr/bin/grep -Fxq -- '-KILL 101' "$CMUX_TEST_SIGNALS" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_DEADLINE_CALLS": root.appendingPathComponent("deadline-calls").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_GROUPS": root.appendingPathComponent("groups").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
                "CMUX_TEST_OWNED_NEXT": root.appendingPathComponent("owned.next").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func ownershipExpansionRejectsReusedPIDWithChangedParentOrGroup(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-reused-pid-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        printf '101 1 11 Thu_Jan_1_00:00:00_1970 S\n102 1 12 Thu_Jan_1_00:00:00_1970 S\n103 1 13 Thu_Jan_1_00:00:00_1970 S\n' \
          > "$CMUX_TEST_OWNED"
        printf '101 9 11 S Thu Jan 1 00:00:00 1970\n102 1 99 S Thu Jan 1 00:00:00 1970\n103 1 13 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_owned_group=777
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_expand_owned_processes "$CMUX_TEST_SNAPSHOT" || exit 99
        test "$(/usr/bin/wc -l < "$CMUX_TEST_OWNED" | /usr/bin/tr -d '[:space:]')" -eq 1 || exit 98
        /usr/bin/grep -Fqx '103 1 13 Thu_Jan_1_00:00:00_1970 T' "$CMUX_TEST_OWNED" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
                "CMUX_TEST_OWNED_NEXT": root.appendingPathComponent("owned.next").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func emptyFrozenProcessSetRequiresNoForce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-empty-frozen-\(UUID().uuidString)", isDirectory: true)
        let frozenFile = root.appendingPathComponent("frozen")
        let orderedFile = root.appendingPathComponent("ordered")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: frozenFile)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_force_frozen_processes
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_FROZEN": frozenFile.path,
                "CMUX_TEST_ORDERED": orderedFile.path,
            ]
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func ordersDuplicateFrozenProcessRecordsWithoutCycling() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-duplicate-frozen-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("frozen")
        let output = root.appendingPathComponent("ordered")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        900001 1 900001 Thu_Aug_6_08:00:00_2026 S
        900001 1 900001 Thu_Aug_6_08:00:00_2026 S
        900002 900001 900001 Thu_Aug_6_08:00:01_2026 S
        900002 900001 900001 Thu_Aug_6_08:00:01_2026 S
        """.write(to: input, atomically: true, encoding: .utf8)

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let command = """
        ulimit -t 1
        \(policy.processTreeTerminationShellFunction())
        cmux_ssh_auth_order_children_first "$CMUX_TEST_FROZEN" "$CMUX_TEST_ORDERED"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_FROZEN": input.path,
            "CMUX_TEST_ORDERED": output.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture, timeout: 3)

        let orderedPIDs = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { $0.split(separator: " ").dropFirst().first }
        #expect(process.terminationStatus == 0)
        #expect(orderedPIDs == ["900002", "900001"])
    }

    @Test func doesNotRunSharedGroupTermHandlerDuringCleanup() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-shared-handler-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let termHandlerMarker = root.appendingPathComponent("term-handler")
        let replacementScript = root.appendingPathComponent("replacement.sh")
        let replacementPIDFile = root.appendingPathComponent("replacement.pid")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" > "$CMUX_TEST_REPLACEMENT_PID"
        while :; do /bin/sleep 30; done
        """.write(to: replacementScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacementScript.path)

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap ': > "$CMUX_TEST_TERM_HANDLER_MARKER"; /usr/bin/nohup /bin/sh "$CMUX_TEST_REPLACEMENT_SCRIPT" </dev/null >/dev/null 2>&1 & exit 143' TERM; : > "$CMUX_TEST_READY_MARKER"; while :; do /bin/sleep 30; done ) &
        cmux_test_auth_root=$!
        cmux_test_ready_attempt=0
        while [ ! -f "$CMUX_TEST_READY_MARKER" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        test ! -e "$CMUX_TEST_TERM_HANDLER_MARKER"
        test ! -s "$CMUX_TEST_REPLACEMENT_PID"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_READY_MARKER": readyMarker.path,
            "CMUX_TEST_TERM_HANDLER_MARKER": termHandlerMarker.path,
            "CMUX_TEST_REPLACEMENT_SCRIPT": replacementScript.path,
            "CMUX_TEST_REPLACEMENT_PID": replacementPIDFile.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let replacementPID = (try? String(contentsOf: replacementPIDFile, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let replacementPID {
            Darwin.kill(replacementPID, SIGKILL)
        }

        #expect(process.terminationStatus == 0)
        #expect(replacementPID == nil)
    }

    @Test func naturalCompletionLeavesNoOwnedProcessGroupMembers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-natural-cleanup-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let releaseMarker = root.appendingPathComponent("release")
        let leafScript = root.appendingPathComponent("leaf.sh")
        let leafPIDFile = root.appendingPathComponent("leaf.pid")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let groupFile = groupDirectory.appendingPathComponent("identity")
        let groupRecord = root.appendingPathComponent("group-record")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" > "$CMUX_TEST_LEAF_PID"
        while :; do /bin/sleep 30; done
        """.write(to: leafScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leafScript.path)

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            /usr/bin/nohup /bin/sh "$CMUX_TEST_LEAF_SCRIPT" </dev/null >/dev/null 2>&1 &
            cmux_test_leaf_attempt=0
            while [ ! -s "$CMUX_TEST_LEAF_PID" ] && [ "$cmux_test_leaf_attempt" -lt 300 ]; do
              /bin/sleep 0.01
              cmux_test_leaf_attempt=$((cmux_test_leaf_attempt + 1))
            done
            test -s "$CMUX_TEST_LEAF_PID" || exit 95
            : > "$CMUX_TEST_READY_MARKER"
            while [ ! -f "$CMUX_TEST_RELEASE_MARKER" ]; do /bin/sleep 0.01; done
            """
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        cmux_test_ready_attempt=0
        while { [ ! -f "$CMUX_TEST_READY_MARKER" ] || [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; } && \
          [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 97
        /bin/cp "$CMUX_SSH_AUTH_GROUP_DIR/identity" "$CMUX_TEST_GROUP_RECORD" || exit 96
        : > "$CMUX_TEST_RELEASE_MARKER"
        wait "$cmux_test_auth_root"
        cmux_ssh_terminate_owned_auth_group
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_READY_MARKER": readyMarker.path,
            "CMUX_TEST_RELEASE_MARKER": releaseMarker.path,
            "CMUX_TEST_LEAF_SCRIPT": leafScript.path,
            "CMUX_TEST_LEAF_PID": leafPIDFile.path,
            "CMUX_TEST_GROUP_RECORD": groupRecord.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let leafPID = try #require(Int32(
            String(contentsOf: leafPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(leafPID, SIGKILL) }
        let exitDeadline = Date.now.addingTimeInterval(1)
        while Darwin.kill(leafPID, 0) == 0, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let groupID = try #require(processGroupID(in: groupRecord))
        defer { Darwin.kill(-groupID, SIGKILL) }
        #expect(process.terminationStatus == 0)
        #expect(Darwin.kill(leafPID, 0) != 0)
        #expect(Darwin.kill(-groupID, 0) != 0)
        #expect(!fileManager.fileExists(atPath: groupFile.path))
        #expect(!fileManager.fileExists(atPath: groupDirectory.path))
    }

    @Test func reaperStopsAfterBoundedFailuresAndPreservesState() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-bounded-reaper-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "anchor|group|started\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_terminate_owned_auth_group() {
          printf x >> "$CMUX_TEST_REAPER_CALLS"
          return 1
        }
        cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
        cmux_test_reaper_pid=$!
        ( /bin/sleep 5; /bin/kill -KILL "$cmux_test_reaper_pid" 2>/dev/null || true ) &
        cmux_test_watchdog_pid=$!
        wait "$cmux_test_reaper_pid"
        cmux_test_reaper_status=$?
        /bin/kill -KILL "$cmux_test_watchdog_pid" 2>/dev/null || true
        wait "$cmux_test_watchdog_pid" 2>/dev/null || true
        test "$cmux_test_reaper_status" -eq 0 || exit 95
        test "$(/usr/bin/wc -c < "$CMUX_TEST_REAPER_CALLS" | /usr/bin/tr -d '[:space:]')" -eq 3 || exit 94
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 93
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed" || exit 92
        test ! -d "$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock" || exit 91
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_REAPER_CALLS": callsFile.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func concurrentReaperLaunchKeepsFreshUnpublishedLockOwnedByCreator(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-reaper-publication-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "anchor|group|started\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_identity() {
          if [ "$1" = "$$" ] && \
            /bin/mkdir "$CMUX_TEST_FIRST_IDENTITY_GATE" 2>/dev/null; then
            : > "$CMUX_TEST_FIRST_READY"
            cmux_test_release_attempt=0
            while [ ! -e "$CMUX_TEST_RELEASE_FIRST" ] && \
              [ "$cmux_test_release_attempt" -lt 500 ]; do
              /bin/sleep 0.01
              cmux_test_release_attempt=$((cmux_test_release_attempt + 1))
            done
            test -e "$CMUX_TEST_RELEASE_FIRST" || return 1
          fi
          printf '1|1|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_terminate_owned_auth_group() { return 1; }
        cmux_test_launch() {
          cmux_test_result_file="$1"
          cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
          cmux_test_launched="${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}"
          cmux_test_reaper_pid=$!
          printf '%s\n' "$cmux_test_launched" > "$cmux_test_result_file"
          if [ "$cmux_test_launched" = 1 ]; then
            wait "$cmux_test_reaper_pid"
          fi
        }
        cmux_test_launch "$CMUX_TEST_FIRST_RESULT" &
        cmux_test_first_launcher=$!
        cmux_test_ready_attempt=0
        while [ ! -e "$CMUX_TEST_FIRST_READY" ] && \
          [ "$cmux_test_ready_attempt" -lt 500 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -e "$CMUX_TEST_FIRST_READY" || exit 99
        cmux_test_launch "$CMUX_TEST_SECOND_RESULT" &
        cmux_test_second_launcher=$!
        cmux_test_second_attempt=0
        while [ ! -s "$CMUX_TEST_SECOND_RESULT" ] && \
          [ "$cmux_test_second_attempt" -lt 500 ]; do
          /bin/sleep 0.01
          cmux_test_second_attempt=$((cmux_test_second_attempt + 1))
        done
        test -s "$CMUX_TEST_SECOND_RESULT" || exit 98
        : > "$CMUX_TEST_RELEASE_FIRST"
        wait "$cmux_test_first_launcher" || exit 97
        wait "$cmux_test_second_launcher" || exit 96
        cmux_test_launch_count=$((
          $(/bin/cat "$CMUX_TEST_FIRST_RESULT") +
          $(/bin/cat "$CMUX_TEST_SECOND_RESULT")
        ))
        test "$cmux_test_launch_count" -eq 1 || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_FIRST_IDENTITY_GATE": root.appendingPathComponent("first-gate").path,
                "CMUX_TEST_FIRST_READY": root.appendingPathComponent("first-ready").path,
                "CMUX_TEST_FIRST_RESULT": root.appendingPathComponent("first-result").path,
                "CMUX_TEST_RELEASE_FIRST": root.appendingPathComponent("release-first").path,
                "CMUX_TEST_SECOND_RESULT": root.appendingPathComponent("second-result").path,
                "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func authenticationGroupFactoryRegistersBeforeReturningDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-factory-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_test_group=$(cmux_ssh_auth_create_group_dir) || exit 99
        test -d "$cmux_test_group" || exit 98
        test "$(/usr/bin/stat -f '%u:%Lp' "$cmux_test_group")" = \
          "$(/usr/bin/id -u):700" || exit 97
        /usr/bin/grep -Fxq "$cmux_test_group" \
          "$TMPDIR/cmux-ssh-auth-recovery/queue.0" || exit 96
        cmux_test_created=$(/bin/cat "$cmux_test_group/created") || exit 95
        case "$cmux_test_created" in ''|*[!0-9]*) exit 94 ;; esac
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoveryQueueSerializesConcurrentEnqueues() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-concurrent-queue-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        : > "$CMUX_TEST_FAILURES"
        cmux_test_index=0
        while [ "$cmux_test_index" -lt 16 ]; do
          (
            cmux_ssh_auth_recovery_enqueue \
              "$TMPDIR/cmux-ssh-auth-group.concurrent-$cmux_test_index" || \
              printf x >> "$CMUX_TEST_FAILURES"
          ) &
          cmux_test_index=$((cmux_test_index + 1))
        done
        wait
        test ! -s "$CMUX_TEST_FAILURES" || exit 99
        /bin/cat "$TMPDIR/cmux-ssh-auth-recovery/queue.0" \
          "$TMPDIR/cmux-ssh-auth-recovery/queue.1" > "$CMUX_TEST_ENTRIES" || exit 98
        test "$(/usr/bin/wc -l < "$CMUX_TEST_ENTRIES" | /usr/bin/tr -d '[:space:]')" -eq 16 || exit 97
        test "$(/usr/bin/sort -u "$CMUX_TEST_ENTRIES" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" -eq 16 || exit 96
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_TEST_ENTRIES": root.appendingPathComponent("entries").path,
            "CMUX_TEST_FAILURES": root.appendingPathComponent("failures").path,
            "TMPDIR": root.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoveryLockRemainsHeldUntilDescriptorCloses() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-descriptor-lock-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_recovery_lock || exit 99
        if /usr/bin/lockf -s -t 0 \
          "$TMPDIR/cmux-ssh-auth-recovery/lock" /usr/bin/true; then
          cmux_ssh_auth_recovery_unlock
          exit 98
        fi
        cmux_ssh_auth_recovery_unlock
        /usr/bin/lockf -s -t 1 \
          "$TMPDIR/cmux-ssh-auth-recovery/lock" /usr/bin/true || exit 97
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func completedAuthenticationCleanupDrainsLongLivedRecoveryQueue() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-cleanup-drain-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let cleanupBody = policy.authenticationGroupDirectoryCleanupShellBody(
            terminatesPublishedGroup: false
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        cmux_test_cleanup_auth_group() { \(cleanupBody) }
        cmux_test_attempt=0
        while [ "$cmux_test_attempt" -lt 20 ]; do
          CMUX_SSH_AUTH_GROUP_DIR=$(cmux_ssh_auth_create_group_dir) || exit 99
          export CMUX_SSH_AUTH_GROUP_DIR
          cmux_test_group="$CMUX_SSH_AUTH_GROUP_DIR"
          cmux_test_cleanup_auth_group
          test ! -d "$cmux_test_group" || exit 98
          cmux_test_attempt=$((cmux_test_attempt + 1))
        done
        for cmux_test_segment in "$TMPDIR/cmux-ssh-auth-recovery"/queue.[0-9]*; do
          if [ -e "$cmux_test_segment" ]; then exit 97; fi
        done
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func laterRecoverySweepReclaimsFailedAuthenticationGroup() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-sweep-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("cmux-ssh-auth-group.test", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls")
        let allowCleanupFile = root.appendingPathComponent("allow-cleanup")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "anchor|group|started\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_terminate_owned_auth_group() {
          printf x >> "$CMUX_TEST_REAPER_CALLS"
          if [ -e "$CMUX_TEST_ALLOW_CLEANUP" ]; then
            /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/identity"
          fi
        }
        cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
        cmux_test_first_reaper=$!
        wait "$cmux_test_first_reaper" || exit 97
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/reaper.failed" || exit 96
        : > "$CMUX_TEST_ALLOW_CLEANUP"
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$TMPDIR/cmux-ssh-auth-group.test" || exit 95
        cmux_ssh_resume_failed_auth_group_reapers || exit 94
        cmux_test_recovery_attempt=0
        while [ -d "$TMPDIR/cmux-ssh-auth-group.test" ] && \
          [ "$cmux_test_recovery_attempt" -lt 500 ]; do
          /bin/sleep 0.01
          cmux_test_recovery_attempt=$((cmux_test_recovery_attempt + 1))
        done
        test ! -d "$TMPDIR/cmux-ssh-auth-group.test" || exit 92
        test "$(/usr/bin/wc -c < "$CMUX_TEST_REAPER_CALLS" | /usr/bin/tr -d '[:space:]')" -eq 4 || exit 91
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_ALLOW_CLEANUP": allowCleanupFile.path,
            "CMUX_TEST_REAPER_CALLS": callsFile.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
            "TMPDIR": root.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
    }

    @Test func recoverySweepReclaimsPublishedOrphanAndSkipsLivePublisher() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-published-recovery-\(UUID().uuidString)", isDirectory: true)
        let orphanDirectory = root.appendingPathComponent("cmux-ssh-auth-group.orphan", isDirectory: true)
        let liveDirectory = root.appendingPathComponent("cmux-ssh-auth-group.live", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: orphanDirectory)
        try createSecureGroupDirectory(at: liveDirectory)
        for directory in [orphanDirectory, liveDirectory] {
            try "999999|888888|Thu_Jan_1_00:00:00_1970\n".write(
                to: directory.appendingPathComponent("identity"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_test_live_publisher_identity=$(cmux_ssh_auth_identity "$$") || exit 98
        printf '%s|%s\n' "$$" "$cmux_test_live_publisher_identity" \
          > "$CMUX_TEST_LIVE_GROUP/publisher" || exit 97
        cmux_ssh_terminate_owned_auth_group() {
          /usr/bin/basename "$CMUX_SSH_AUTH_GROUP_DIR" >> "$CMUX_TEST_RECOVERY_CALLS"
          /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/identity" \
            "$CMUX_SSH_AUTH_GROUP_DIR/publisher" 2>/dev/null || true
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_ORPHAN_GROUP" || exit 96
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_LIVE_GROUP" || exit 95
        cmux_ssh_resume_failed_auth_group_reapers || exit 94
        wait
        test "$(/bin/cat "$CMUX_TEST_RECOVERY_CALLS" 2>/dev/null)" = \
          "cmux-ssh-auth-group.orphan" || exit 95
        test -s "$CMUX_TEST_LIVE_GROUP/identity" || exit 94
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_TEST_LIVE_GROUP": liveDirectory.path,
            "CMUX_TEST_ORPHAN_GROUP": orphanDirectory.path,
            "CMUX_TEST_RECOVERY_CALLS": callsFile.path,
            "TMPDIR": root.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySweepRequiresAbandonedCleanupRecordBeforeReapingStoppedPublisher(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-stopped-publisher-\(UUID().uuidString)", isDirectory: true)
        let suspendedDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.suspended", isDirectory: true)
        let abandonedDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.abandoned", isDirectory: true)
        let activeDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.active", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: suspendedDirectory)
        try createSecureGroupDirectory(at: abandonedDirectory)
        try createSecureGroupDirectory(at: activeDirectory)
        for directory in [suspendedDirectory, abandonedDirectory, activeDirectory] {
            try "999999|888888|Thu_Jan_1_00:00:00_1970\n".write(
                to: directory.appendingPathComponent("identity"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        /bin/sleep 30 &
        cmux_test_suspended_publisher=$!
        /bin/sleep 30 &
        cmux_test_abandoned_publisher=$!
        /bin/sleep 30 &
        cmux_test_active_publisher=$!
        trap '/bin/kill -KILL "$cmux_test_suspended_publisher" "$cmux_test_abandoned_publisher" "$cmux_test_active_publisher" >/dev/null 2>&1 || true; wait "$cmux_test_suspended_publisher" "$cmux_test_abandoned_publisher" "$cmux_test_active_publisher" 2>/dev/null || true' EXIT
        cmux_test_suspended_identity=$(cmux_ssh_auth_identity "$cmux_test_suspended_publisher") || exit 100
        cmux_test_abandoned_identity=$(cmux_ssh_auth_identity "$cmux_test_abandoned_publisher") || exit 99
        cmux_test_active_identity=$(cmux_ssh_auth_identity "$cmux_test_active_publisher") || exit 98
        printf '%s|%s\n' "$cmux_test_suspended_publisher" "$cmux_test_suspended_identity" \
          > "$CMUX_TEST_SUSPENDED_GROUP/publisher" || exit 97
        printf '%s|%s\n' "$cmux_test_abandoned_publisher" "$cmux_test_abandoned_identity" \
          > "$CMUX_TEST_ABANDONED_GROUP/publisher" || exit 96
        printf '%s|%s\n' "$cmux_test_active_publisher" "$cmux_test_active_identity" \
          > "$CMUX_TEST_ACTIVE_GROUP/publisher" || exit 95
        printf '999999|888888|777777|Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_TEST_ABANDONED_GROUP/cleanup.owner" || exit 94
        : > "$CMUX_TEST_ABANDONED_GROUP/cancel" || exit 93
        cmux_test_cleanup_owner_identity=$(cmux_ssh_auth_identity "$$") || exit 95
        printf '%s|%s\n' "$$" "$cmux_test_cleanup_owner_identity" \
          > "$CMUX_TEST_ACTIVE_GROUP/cleanup.owner" || exit 92
        : > "$CMUX_TEST_ACTIVE_GROUP/cancel" || exit 91
        /bin/kill -STOP "$cmux_test_suspended_publisher" \
          "$cmux_test_abandoned_publisher" "$cmux_test_active_publisher" || exit 90
        cmux_test_stop_attempt=0
        while [ "$cmux_test_stop_attempt" -lt 100 ]; do
          if [ "$(cmux_ssh_auth_stopped_identity "$cmux_test_suspended_publisher")" = \
            "$cmux_test_suspended_identity" ] && \
            [ "$(cmux_ssh_auth_stopped_identity "$cmux_test_abandoned_publisher")" = \
            "$cmux_test_abandoned_identity" ] && \
            [ "$(cmux_ssh_auth_stopped_identity "$cmux_test_active_publisher")" = \
            "$cmux_test_active_identity" ]; then break; fi
          /bin/sleep 0.01
          cmux_test_stop_attempt=$((cmux_test_stop_attempt + 1))
        done
        test "$cmux_test_stop_attempt" -lt 100 || exit 89
        cmux_ssh_terminate_owned_auth_group() {
          /usr/bin/basename "$CMUX_SSH_AUTH_GROUP_DIR" >> "$CMUX_TEST_RECOVERY_CALLS"
          /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/identity" \
            "$CMUX_SSH_AUTH_GROUP_DIR/publisher" 2>/dev/null || true
        }
        cmux_ssh_launch_owned_auth_group_reaper() {
          CMUX_SSH_AUTH_REAPER_LAUNCHED=1
          (CMUX_SSH_AUTH_GROUP_DIR="$1"
            export CMUX_SSH_AUTH_GROUP_DIR
            cmux_ssh_terminate_owned_auth_group)
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_SUSPENDED_GROUP" || exit 88
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_ABANDONED_GROUP" || exit 87
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_ACTIVE_GROUP" || exit 86
        cmux_ssh_resume_failed_auth_group_reapers || exit 85
        test "$(/bin/cat "$CMUX_TEST_RECOVERY_CALLS" 2>/dev/null)" = \
          "cmux-ssh-auth-group.abandoned" || exit 84
        test -s "$CMUX_TEST_SUSPENDED_GROUP/identity" || exit 83
        test -s "$CMUX_TEST_ACTIVE_GROUP/identity" || exit 82
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_ABANDONED_GROUP": abandonedDirectory.path,
                "CMUX_TEST_ACTIVE_GROUP": activeDirectory.path,
                "CMUX_TEST_RECOVERY_CALLS": callsFile.path,
                "CMUX_TEST_SUSPENDED_GROUP": suspendedDirectory.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoverySweepDoesNotStarveGroupsAfterEightPersistentFailures() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-fairness-\(UUID().uuidString)", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<9 {
            let groupDirectory = root.appendingPathComponent(
                String(format: "cmux-ssh-auth-group.%02d", index),
                isDirectory: true
            )
            try createSecureGroupDirectory(at: groupDirectory)
            try "999999|888888|Thu_Jan_1_00:00:00_1970\n".write(
                to: groupDirectory.appendingPathComponent("identity"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_launch_owned_auth_group_reaper() {
          CMUX_SSH_AUTH_REAPER_LAUNCHED=1
          /usr/bin/basename "$1" >> "$CMUX_TEST_RECOVERY_CALLS"
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        for cmux_test_group_dir in "$TMPDIR"/cmux-ssh-auth-group.*; do
          cmux_ssh_auth_recovery_enqueue "$cmux_test_group_dir" || exit 99
        done
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        cmux_ssh_resume_failed_auth_group_reapers || exit 97
        /usr/bin/grep -qx 'cmux-ssh-auth-group.08' "$CMUX_TEST_RECOVERY_CALLS" || exit 96
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_TEST_RECOVERY_CALLS": callsFile.path,
            "TMPDIR": root.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoveryCompletionFailureCannotLeaveLiveClaimOwner(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-claim-failure-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("cmux-ssh-auth-group.test", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_recovery_complete_segment() {
          /bin/chmod 500 "$TMPDIR/cmux-ssh-auth-recovery" || exit 99
          return 1
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$TMPDIR/cmux-ssh-auth-group.test" || exit 98
        cmux_ssh_resume_failed_auth_group_reapers || exit 97
        /bin/chmod 700 "$TMPDIR/cmux-ssh-auth-recovery" || exit 96
        test -s "$TMPDIR/cmux-ssh-auth-recovery/queue.0.claim" || exit 95
        cmux_ssh_auth_recovery_claim_segment || exit 94
        test "$CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX" = 0 || exit 93
        """

        let result = try runShellCommand(
            command,
            environment: ["TMPDIR": root.path],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func anchorValidationFailurePreservesPublishedOwnershipState() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-validation-preserve-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "999999|888888|Thu_Jan_1_00:00:00_1970\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_identity() { return 1; }
        cmux_ssh_terminate_owned_auth_group 777777
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoverySweepReclaimsExpiredDeadAnchorState() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-expired-orphan-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("cmux-ssh-auth-group.expired", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "999999|888888|Thu_Jan_1_00:00:00_1970\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        try "1\n".write(
            to: groupDirectory.appendingPathComponent("orphaned"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_launch_owned_auth_group_reaper() {
          CMUX_SSH_AUTH_REAPER_LAUNCHED=0
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$TMPDIR/cmux-ssh-auth-group.expired" || exit 99
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        test ! -d "$TMPDIR/cmux-ssh-auth-group.expired" || exit 97
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoveryQueueProcessesOneBoundedSegmentPerSweep() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-batch-\(UUID().uuidString)", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<9 {
            let groupDirectory = root.appendingPathComponent(
                String(format: "cmux-ssh-auth-group.%02d", index),
                isDirectory: true
            )
            try createSecureGroupDirectory(at: groupDirectory)
            try "999999|888888|Thu_Jan_1_00:00:00_1970\n".write(
                to: groupDirectory.appendingPathComponent("identity"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_launch_owned_auth_group_reaper() {
          /usr/bin/basename "$1" >> "$CMUX_TEST_RECOVERY_CALLS"
          CMUX_SSH_AUTH_REAPER_LAUNCHED=0
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        for cmux_test_group_dir in "$TMPDIR"/cmux-ssh-auth-group.*; do
          cmux_ssh_auth_recovery_enqueue "$cmux_test_group_dir" || exit 99
        done
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        test "$(/usr/bin/wc -l < "$CMUX_TEST_RECOVERY_CALLS" | /usr/bin/tr -d '[:space:]')" -eq 8 || exit 97
        /usr/bin/grep -qx 'cmux-ssh-auth-group.08' "$CMUX_TEST_RECOVERY_CALLS" && exit 96
        : > "$CMUX_TEST_RECOVERY_CALLS"
        cmux_ssh_resume_failed_auth_group_reapers || exit 95
        /usr/bin/grep -qx 'cmux-ssh-auth-group.08' "$CMUX_TEST_RECOVERY_CALLS" || exit 94
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_TEST_RECOVERY_CALLS": callsFile.path,
            "TMPDIR": root.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoveryQueueReclaimsExpiredUnpublishedDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-unpublished-orphan-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("cmux-ssh-auth-group.unpublished", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "1\n".write(
            to: groupDirectory.appendingPathComponent("created"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$TMPDIR/cmux-ssh-auth-group.unpublished" || exit 99
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        test ! -d "$TMPDIR/cmux-ssh-auth-group.unpublished" || exit 97
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func laterRecoverySweepReclaimsDeadReaperLockOwner() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-stale-reaper-lock-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("cmux-ssh-auth-group.test", isDirectory: true)
        let lockDirectory = groupDirectory.appendingPathComponent("reaper.lock", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try fileManager.createDirectory(at: lockDirectory, withIntermediateDirectories: false)
        try "anchor|group|started\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        try "cleanup-incomplete attempts=3\n".write(
            to: groupDirectory.appendingPathComponent("reaper.failed"),
            atomically: true,
            encoding: .utf8
        )
        try "999999|1|999999|Thu_Jan_1_00:00:00_1970\n".write(
            to: lockDirectory.appendingPathComponent("owner"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_terminate_owned_auth_group() {
          /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$TMPDIR/cmux-ssh-auth-group.test" || exit 98
        cmux_ssh_resume_failed_auth_group_reapers
        cmux_test_recovery_attempt=0
        while [ -d "$TMPDIR/cmux-ssh-auth-group.test" ] && \
          [ "$cmux_test_recovery_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_recovery_attempt=$((cmux_test_recovery_attempt + 1))
        done
        test ! -d "$TMPDIR/cmux-ssh-auth-group.test"
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: [("HUP", Int32(129)), ("INT", Int32(130)), ("TERM", Int32(143))])
    func directProcessGroupSignalIsReapedByCaller(
        signalName: String,
        expectedStatus: Int32
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-direct-signal-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let groupFile = groupDirectory.appendingPathComponent("identity")
        let groupRecord = root.appendingPathComponent("group-record")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: ": > \"$CMUX_TEST_READY_MARKER\"; while :; do /bin/sleep 30; done"
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        cmux_test_ready_attempt=0
        while { [ ! -f "$CMUX_TEST_READY_MARKER" ] || [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; } && \
          [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 97
        /bin/cp "$CMUX_SSH_AUTH_GROUP_DIR/identity" "$CMUX_TEST_GROUP_RECORD" || exit 96
        cmux_test_auth_group=$(/usr/bin/awk -F '|' '{ print $2 }' "$CMUX_SSH_AUTH_GROUP_DIR/identity")
        /bin/kill -\(signalName) -- "-$cmux_test_auth_group" || exit 95
        wait "$cmux_test_auth_root"
        cmux_test_auth_status=$?
        test "$cmux_test_auth_status" -eq \(expectedStatus) || exit 94
        cmux_ssh_terminate_owned_auth_group
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_READY_MARKER": readyMarker.path,
            "CMUX_TEST_GROUP_RECORD": groupRecord.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
            "LC_ALL": "fr_FR.UTF-8",
            "LANG": "fr_FR.UTF-8",
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let groupID = try #require(processGroupID(in: groupRecord))
        defer { Darwin.kill(-groupID, SIGKILL) }
        #expect(process.terminationStatus == 0)
        #expect(Darwin.kill(-groupID, 0) != 0)
        #expect(!fileManager.fileExists(atPath: groupFile.path))
        #expect(!fileManager.fileExists(atPath: groupDirectory.path))
    }

    @Test func cancellationBeforeGroupPublicationPreventsAuthenticationStart() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-prepublish-cancel-\(UUID().uuidString)", isDirectory: true)
        let commandStartedMarker = root.appendingPathComponent("command-started")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: ": > \"$CMUX_TEST_COMMAND_STARTED_MARKER\"; while :; do /bin/sleep 30; done"
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        cmux_ssh_terminate_owned_auth_group &
        cmux_test_cleanup_pid=$!
        cmux_test_cancel_attempt=0
        while [ ! -f "$CMUX_SSH_AUTH_GROUP_DIR/cancel" ] && \
          [ "$cmux_test_cancel_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_cancel_attempt=$((cmux_test_cancel_attempt + 1))
        done
        test -f "$CMUX_SSH_AUTH_GROUP_DIR/cancel" || exit 98
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        wait "$cmux_test_auth_root"
        cmux_test_auth_status=$?
        wait "$cmux_test_cleanup_pid" 2>/dev/null || true
        test "$cmux_test_auth_status" -eq 143 || exit 97
        test ! -e "$CMUX_TEST_COMMAND_STARTED_MARKER" || exit 96
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_COMMAND_STARTED_MARKER": commandStartedMarker.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
        #expect(!fileManager.fileExists(atPath: commandStartedMarker.path))
        #expect(!fileManager.fileExists(atPath: groupDirectory.path))
    }

    @Test func cancellationDuringGroupPublicationReapsAuthenticationSubtree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-publishing-cancel-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let pendingIdentity = groupDirectory.appendingPathComponent("identity.new")
        let processSnapshot = root.appendingPathComponent("processes")
        let ownedPIDs = root.appendingPathComponent("owned-pids")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        #expect(Darwin.mkfifo(pendingIdentity.path, 0o600) == 0)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: "while :; do /bin/sleep 30; done"
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        cmux_test_publish_attempt=0
        while { [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/publisher.new" ] || \
          [ -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ]; } && \
          [ "$cmux_test_publish_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_publish_attempt=$((cmux_test_publish_attempt + 1))
        done
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/publisher.new" || exit 99
        test ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 98
        /usr/bin/env LC_ALL=C LANG=C /bin/ps -axo pid=,ppid=,state= \
          > "$CMUX_TEST_PROCESS_SNAPSHOT" || exit 97
        /usr/bin/awk -v cmux_root="$cmux_test_auth_root" '
          NF >= 3 && $3 !~ /Z/ {
            cmux_process[$1] = 1
            cmux_next_sibling[$1] = cmux_first_child[$2]
            cmux_first_child[$2] = $1
          }
          END {
            if (!(cmux_root in cmux_process)) exit 1
            cmux_owned[cmux_root] = 1
            cmux_queue[++cmux_queue_tail] = cmux_root
            for (cmux_queue_head = 1; cmux_queue_head <= cmux_queue_tail; cmux_queue_head += 1) {
              cmux_parent = cmux_queue[cmux_queue_head]
              for (cmux_child = cmux_first_child[cmux_parent];
                   cmux_child != "";
                   cmux_child = cmux_next_sibling[cmux_child]) {
                if (!(cmux_child in cmux_owned)) {
                  cmux_owned[cmux_child] = 1
                  cmux_queue[++cmux_queue_tail] = cmux_child
                }
              }
            }
            for (cmux_pid in cmux_owned) print cmux_pid
          }
        ' "$CMUX_TEST_PROCESS_SNAPSHOT" | /usr/bin/sort -n \
          > "$CMUX_TEST_OWNED_PIDS" || exit 96
        test "$(/usr/bin/wc -l < "$CMUX_TEST_OWNED_PIDS" | /usr/bin/tr -d '[:space:]')" \
          -ge 3 || exit 95
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
            "CMUX_TEST_OWNED_PIDS": ownedPIDs.path,
            "CMUX_TEST_PROCESS_SNAPSHOT": processSnapshot.path,
        ])
        let pids = try String(contentsOf: ownedPIDs, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { Int32($0) }
        defer {
            for pid in pids {
                Darwin.kill(pid, SIGKILL)
            }
        }
        let exitDeadline = Date.now.addingTimeInterval(1)
        while pids.contains(where: { Darwin.kill($0, 0) == 0 }), Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        #expect(pids.allSatisfy { Darwin.kill($0, 0) != 0 })
    }

    @Test func refusesAuthenticationRootWithMismatchedKnownParent() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-root-parent-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap '' HUP INT TERM; : > "$CMUX_TEST_READY_MARKER"; while :; do /bin/sleep 30; done ) &
        cmux_test_auth_root=$!
        trap '/bin/kill -KILL "$cmux_test_auth_root" >/dev/null 2>&1 || true' EXIT
        cmux_test_ready_attempt=0
        while [ ! -f "$CMUX_TEST_READY_MARKER" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" 1
        /bin/kill -0 "$cmux_test_auth_root" >/dev/null 2>&1 || exit 97
        /bin/kill -KILL "$cmux_test_auth_root" >/dev/null 2>&1 || true
        wait "$cmux_test_auth_root" 2>/dev/null || true
        trap - EXIT
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_READY_MARKER": readyMarker.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
    }

    @Test func ownedProcessSignalsStayInCleanupShellProcess() {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .ownedProcessGroupTerminationShellFunctions()

        #expect(
            !functions.contains("/bin/kill"),
            "Owned-process signaling must not fork and exec once per PID inside a bounded deadline"
        )
        #expect(functions.contains("kill -STOP"))
        #expect(functions.contains("kill -KILL"))
        #expect(functions.contains("kill -CONT"))
    }

    @Test func cleanupPublishesOwnerLeaseBeforeFreezeTransaction() throws {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()
        let ownerPublication = try #require(
            functions.range(of: "cmux-cleanup-owner \"$cmux_ssh_auth_cleanup_owner_publish_file\"")
        )
        let cleanupTransaction = try #require(
            functions.range(of: "cmux_ssh_auth_run_cleanup_transactions || exit 0")
        )

        #expect(ownerPublication.lowerBound < cleanupTransaction.lowerBound)
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func cleanupTransactionReusesValidatedPostStopSnapshot(shellPath: String) throws {
        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_test_snapshot_calls=0
        cmux_ssh_auth_take_process_snapshot() {
          cmux_test_snapshot_calls=$((cmux_test_snapshot_calls + 1))
          : > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_freeze_owned_processes() {
          : > "$cmux_ssh_auth_poststop_snapshot"
        }
        cmux_ssh_auth_force_frozen_processes() {
          test "$1" = "$cmux_ssh_auth_poststop_snapshot"
        }
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_freeze_and_force_owned_processes || exit 99
        test "$cmux_test_snapshot_calls" -eq 1 || exit 98
        """

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_PROCESS_SNAPSHOT": root.appendingPathComponent("processes").path,
                "CMUX_TEST_POSTSTOP_SNAPSHOT": root.appendingPathComponent("poststop").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func validatedFrozenProcessesReachKillCommitPoint(shellPath: String) throws {
        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
        cmux_test_victim_pid=$!
        trap '/bin/kill -KILL "$cmux_test_victim_pid" >/dev/null 2>&1 || true; wait "$cmux_test_victim_pid" 2>/dev/null || true' EXIT
        /bin/kill -STOP "$cmux_test_victim_pid" || exit 97
        /bin/sleep 0.01
        /usr/bin/env LC_ALL=C LANG=C /bin/ps \
          -o pid=,ppid=,pgid=,state=,lstart= -p "$cmux_test_victim_pid" \
          > "$CMUX_TEST_SNAPSHOT" || exit 96
        /usr/bin/awk 'NF >= 9 && $4 ~ /T/ { print $1, $2, $3, $5 "_" $6 "_" $7 "_" $8 "_" $9, $4 }' \
          "$CMUX_TEST_SNAPSHOT" > "$CMUX_TEST_FROZEN" || exit 95
        test -s "$CMUX_TEST_FROZEN" || exit 94
        /bin/cp "$CMUX_TEST_FROZEN" "$CMUX_TEST_OWNED" || exit 93
        : > "$CMUX_TEST_GROUPS"
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_CURRENT"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_FALLBACK_SNAPSHOT"
        cmux_ssh_auth_force_frozen_processes "$CMUX_TEST_SNAPSHOT" || exit 92
        wait "$cmux_test_victim_pid" 2>/dev/null || true
        /bin/kill -0 "$cmux_test_victim_pid" >/dev/null 2>&1 && exit 91
        trap - EXIT
        """

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-commit-point-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FALLBACK_SNAPSHOT": root.appendingPathComponent("fallback-snapshot").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_GROUPS": root.appendingPathComponent("groups").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_ORDERED": root.appendingPathComponent("ordered").path,
                "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func processTreeTerminationUsesOneOverallDeadline(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-deadline-\(UUID().uuidString)", isDirectory: true)
        let chainScript = root.appendingPathComponent("chain.sh")
        let readyMarker = root.appendingPathComponent("ready")
        let pidLog = root.appendingPathComponent("pids")
        let cleanupTimingFile = root.appendingPathComponent("cleanup-timing")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" >> "$CMUX_TEST_PID_LOG"
        cmux_test_depth="${CMUX_TEST_CHAIN_DEPTH:-0}"
        if [ "$cmux_test_depth" -gt 0 ]; then
          CMUX_TEST_CHAIN_DEPTH=$((cmux_test_depth - 1)) /bin/sh "$0" &
        else
          : > "$CMUX_TEST_READY_MARKER"
        fi
        while :; do /bin/sleep 30; done
        """.write(to: chainScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chainScript.path)
        defer {
            let processIDs = (try? String(contentsOf: pidLog, encoding: .utf8))?
                .split(separator: "\n")
                .compactMap { Int32($0) } ?? []
            for processID in processIDs {
                Darwin.kill(processID, SIGKILL)
            }
        }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: "CMUX_TEST_CHAIN_DEPTH=24 /bin/sh \"$CMUX_TEST_CHAIN_SCRIPT\""
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        cmux_test_ready_attempt=0
        while [ ! -f "$CMUX_TEST_READY_MARKER" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        /usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f\\n", time' \
          > "$CMUX_TEST_CLEANUP_TIMING" || exit 97
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        /usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f\\n", time' \
          >> "$CMUX_TEST_CLEANUP_TIMING" || exit 96
        wait "$cmux_test_auth_root" 2>/dev/null || true
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_CHAIN_SCRIPT": chainScript.path,
            "CMUX_TEST_CLEANUP_TIMING": cleanupTimingFile.path,
            "CMUX_TEST_READY_MARKER": readyMarker.path,
            "CMUX_TEST_PID_LOG": pidLog.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture, timeout: 8)
        let cleanupTimestamps = try String(contentsOf: cleanupTimingFile, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { TimeInterval($0) }
        let cleanupStartedAt = try #require(cleanupTimestamps.first)
        let cleanupFinishedAt = try #require(cleanupTimestamps.last)
        let elapsed = cleanupFinishedAt - cleanupStartedAt

        let processIDs = try String(contentsOf: pidLog, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { Int32($0) }
        let exitDeadline = Date.now.addingTimeInterval(1)
        while processIDs.contains(where: { Darwin.kill($0, 0) == 0 }), Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(process.terminationStatus == 0)
        #expect(processIDs.count == 25)
        #expect(
            elapsed < 3,
            "Foreground authentication cleanup took \(elapsed) seconds instead of one bounded deadline"
        )
        let survivingProcessIDs = processIDs.filter { Darwin.kill($0, 0) == 0 }
        #expect(
            survivingProcessIDs.isEmpty,
            "Foreground authentication cleanup left descendants alive: \(survivingProcessIDs)"
        )
    }

    @Test func doesNotRunAuthenticationTermHandlerDuringOwnedGroupCleanup() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-replacement-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let replacementScript = root.appendingPathComponent("replacement.sh")
        let replacementPIDFile = root.appendingPathComponent("replacement.pid")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT TERM
        printf '%s\\n' "$$" > "$CMUX_TEST_REPLACEMENT_PID"
        while :; do /bin/sleep 30; done
        """.write(to: replacementScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacementScript.path)

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            trap '/usr/bin/nohup /usr/bin/script -q /dev/null /bin/sh "$CMUX_TEST_REPLACEMENT_SCRIPT" </dev/null >/dev/null 2>&1 & exit 143' TERM
            : > "$CMUX_TEST_READY_MARKER"
            while :; do /bin/sleep 30; done
            """
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        trap '/bin/kill -KILL "$cmux_test_auth_root" >/dev/null 2>&1 || true' EXIT
        cmux_test_ready_attempt=0
        while [ ! -f "$CMUX_TEST_READY_MARKER" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        cmux_test_replacement_attempt=0
        while [ ! -s "$CMUX_TEST_REPLACEMENT_PID" ] && [ "$cmux_test_replacement_attempt" -lt 100 ]; do
          /bin/sleep 0.01
          cmux_test_replacement_attempt=$((cmux_test_replacement_attempt + 1))
        done
        test ! -s "$CMUX_TEST_REPLACEMENT_PID"
        trap - EXIT
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_READY_MARKER": readyMarker.path,
            "CMUX_TEST_REPLACEMENT_SCRIPT": replacementScript.path,
            "CMUX_TEST_REPLACEMENT_PID": replacementPIDFile.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        let replacementPID = (try? String(contentsOf: replacementPIDFile, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let replacementPID {
            Darwin.kill(replacementPID, SIGKILL)
        }

        #expect(process.terminationStatus == 0)
        #expect(replacementPID == nil)
    }

    @Test func restoresTerminalModesWhenTerminatingForegroundAuthenticationTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-termios-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            trap '' HUP INT TERM
            /bin/stty -echo
            : > "$CMUX_TEST_READY_MARKER"
            while :; do /bin/sleep 30; done
            """
        )
        let command = """
        test -t 0 || exit 96
        cmux_test_terminal_mode_before=$(/bin/stty -g) || exit 97
        \(policy.processTreeTerminationShellFunction())
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        cmux_test_ready_attempt=0
        while [ ! -f "$CMUX_TEST_READY_MARKER" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        cmux_test_terminal_mode_after=$(/bin/stty -g) || exit 99
        test "$cmux_test_terminal_mode_after" = "$cmux_test_terminal_mode_before"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_READY_MARKER": readyMarker.path,
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
    }

    @Test func keepsDiagnosticStateBoundedWhileCommandIsRunning() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-policy-bounds-\(UUID().uuidString)", isDirectory: true)
        let readyFile = temporaryDirectory.appendingPathComponent("producer-ready")
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            SSHForegroundAuthenticationRetryPolicy().classifyingTransientFailure(
                in: """
                /usr/bin/head -c 8192 /dev/zero | /usr/bin/tr '\\000' x >&2
                printf 'Network is unreachable' >&2
                /usr/bin/head -c 4096 /dev/zero | /usr/bin/tr '\\000' x >&2
                : > "$CMUX_TEST_READY_FILE"
                /bin/sleep 3
                exit 255
                """
            ),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path
        environment["CMUX_TEST_READY_FILE"] = readyFile.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        defer {
            terminateIfRunning(process)
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let deadline = Date.now.addingTimeInterval(10)
        while !fileManager.fileExists(atPath: readyFile.path), process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(fileManager.fileExists(atPath: readyFile.path))

        let temporaryEntries = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )
        let diagnosticDirectories = temporaryEntries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        #expect(diagnosticDirectories.count == 1)
        for directory in diagnosticDirectories {
            let permissions = try #require(
                fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            )
            #expect(permissions.intValue & 0o077 == 0)
        }
        let diagnosticFiles = try diagnosticDirectories.flatMap { directory in
            try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: []
            ).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
        let largestDiagnosticFile = try diagnosticFiles
            .map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
            .max() ?? 0

        #expect(
            largestDiagnosticFile <= 64,
            "Foreground authentication must not retain unbounded remote-controlled stderr"
        )
        let classificationDeadline = Date.now.addingTimeInterval(5)
        var classifiedWhileRunning = false
        var lastClassifications: [String] = []
        while process.isRunning, Date.now < classificationDeadline {
            lastClassifications = diagnosticFiles.compactMap {
                try? String(contentsOf: $0, encoding: .utf8)
            }
            if lastClassifications.contains("transient\n") {
                classifiedWhileRunning = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(
            classifiedWhileRunning,
            "A newline-free stderr stream must be classified incrementally with bounded records; observed \(lastClassifications)"
        )
        try waitForExit(process, stderrCapture: stderrCapture)
        #expect(process.terminationStatus == 254)
    }

    private func run(_ command: String) throws -> (
        status: Int32,
        stderr: String,
        temporaryFiles: [String]
    ) {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-policy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let process = Process()
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            SSHForegroundAuthenticationRetryPolicy().classifyingTransientFailure(in: command),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)
        try stderrCapture.handle.close()
        let stderrData = try Data(contentsOf: stderrCapture.url)
        let temporaryFiles = try fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)
        return (
            process.terminationStatus,
            String(data: stderrData, encoding: .utf8) ?? "",
            temporaryFiles
        )
    }

    private func runShellCommand(
        _ command: String,
        environment overrides: [String: String] = [:],
        shellPath: String = "/bin/sh"
    ) throws -> (status: Int32, standardError: String) {
        let process = Process()
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, override in
            override
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)
        try stderrCapture.handle.close()
        let standardError = (try? String(contentsOf: stderrCapture.url, encoding: .utf8)) ?? ""
        return (process.terminationStatus, standardError)
    }

    private func processGroupID(in record: URL) -> Int32? {
        guard let contents = try? String(contentsOf: record, encoding: .utf8) else { return nil }
        let fields = contents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard fields.count == 3 else { return nil }
        return Int32(fields[1])
    }

    private func createSecureGroupDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func makeStandardErrorCapture() throws -> (url: URL, handle: FileHandle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-stderr-\(UUID().uuidString).log")
        try Data().write(to: url, options: .atomic)
        return (
            url: url,
            handle: try FileHandle(forWritingTo: url)
        )
    }

    private func removeStandardErrorCapture(_ capture: (url: URL, handle: FileHandle)) {
        try? capture.handle.close()
        try? FileManager.default.removeItem(at: capture.url)
    }

    private func waitForExit(
        _ process: Process,
        stderrCapture: (url: URL, handle: FileHandle),
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let timedOut = process.isRunning
        if timedOut {
            terminateIfRunning(process)
        }
        try? stderrCapture.handle.synchronize()
        let stderr = (try? String(contentsOf: stderrCapture.url, encoding: .utf8)) ?? ""
        try #require(
            !timedOut,
            "Process timed out after \(timeout) seconds; stderr: \(stderr)"
        )
    }

    private func terminateIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        var deadline = Date.now.addingTimeInterval(1)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            deadline = Date.now.addingTimeInterval(1)
            while process.isRunning, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
}
