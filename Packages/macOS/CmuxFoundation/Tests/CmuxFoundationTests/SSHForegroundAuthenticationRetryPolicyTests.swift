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

    @Test(arguments: [
        "user@example.test: Permission denied (publickey,password).",
        "Bad owner or permissions on /Users/test/.ssh/config",
    ])
    func preservesPermanentAuthenticationFailure(_ diagnostic: String) throws {
        let result = try run(
            "printf '%s\\n' '\(diagnostic)' >&2; exit 255"
        )

        #expect(result.status == 255)
        #expect(result.stderr.contains(diagnostic))
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
          cmux_ssh_auth_take_process_snapshot_until \
            "$1" "$cmux_ssh_auth_deadline_millis"
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
          if [ -e "$CMUX_TEST_DEADLINE_EXPIRED_MARKER" ]; then
            cmux_test_now=$((cmux_test_now + 10))
          else
            cmux_test_now=$((cmux_test_now + 150))
          fi
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
        let remainingGroupState = (
            try? fileManager.contentsOfDirectory(atPath: groupDirectory.path).sorted()
        ) ?? []
        let durableStateFiles = ["cancel", "identity", "publisher"]
        #expect(
            !fileManager.fileExists(atPath: groupDirectory.path) ||
                durableStateFiles.allSatisfy(remainingGroupState.contains),
            "Cleanup left incomplete authentication state behind: \(remainingGroupState)"
        )
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
        cmux_ssh_auth_take_process_snapshot() {
          : > "$CMUX_TEST_POST_TIMEOUT_SNAPSHOT"
          : > "$1"
        }
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
        cmux_ssh_auth_take_process_snapshot() {
          /bin/cp "$CMUX_TEST_SNAPSHOT" "$1"
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
        cmux_ssh_auth_stable_identity() {
          case "$1" in
            101) printf '11|Thu_Jan_1_00:00:00_1970\n' ;;
            102) printf '12|Thu_Jan_1_00:00:00_1970\n' ;;
            *) return 1 ;;
          esac
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
    func forceFrozenProcessesRevalidatesPIDIdentityImmediatelyBeforeKill(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-frozen-pid-reuse-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_stable_identity() {
          printf '11|Fri_Jan_2_00:00:00_1970\n'
        }
        kill() {
          printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"
          return 0
        }
        printf '101 1 11 Thu_Jan_1_00:00:00_1970 T\n' > "$CMUX_TEST_FROZEN"
        /bin/cp "$CMUX_TEST_FROZEN" "$CMUX_TEST_OWNED" || exit 99
        printf '101 1 11 T Thu Jan 1 00:00:00 1970\n' > "$CMUX_TEST_SNAPSHOT"
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        if cmux_ssh_auth_force_frozen_processes "$CMUX_TEST_SNAPSHOT"; then exit 98; fi
        test ! -s "$CMUX_TEST_SIGNALS" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: [
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
    func forceFrozenGroupsRevalidateCurrentMembershipImmediatelyBeforeKill(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-frozen-group-reuse-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '202 1 11 T Fri Jan 2 00:00:00 1970\n' > "$1"
        }
        kill() {
          printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"
          return 0
        }
        : > "$CMUX_TEST_FROZEN"
        printf '101 1 11 Thu_Jan_1_00:00:00_1970 T\n' > "$CMUX_TEST_OWNED"
        printf '11\n' > "$CMUX_TEST_GROUPS"
        printf '101 1 11 T Thu Jan 1 00:00:00 1970\n' > "$CMUX_TEST_INITIAL_SNAPSHOT"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_CURRENT_SNAPSHOT"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        if cmux_ssh_auth_force_frozen_processes "$CMUX_TEST_INITIAL_SNAPSHOT"; then
          exit 98
        fi
        test ! -s "$CMUX_TEST_SIGNALS" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT_SNAPSHOT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_GROUPS": root.appendingPathComponent("groups").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_INITIAL_SNAPSHOT": root.appendingPathComponent("initial").path,
                "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
                "CMUX_TEST_OWNED_NEXT": root.appendingPathComponent("owned.next").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezePassesAbsoluteDeadlineToIdentityValidationAndStopsOnTimeout(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-freeze-identity-deadline-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() { : > "$cmux_ssh_auth_owned_groups"; }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() { : > "$1"; }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_stable_identity() {
          printf '%s|%s\n' "$#" "${2:-}" > "$CMUX_TEST_IDENTITY_CALL"
          return 124
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\n' > "$CMUX_TEST_OWNED"
        cmux_ssh_auth_deadline_millis=4242
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        if cmux_ssh_auth_freeze_owned_processes; then exit 99; fi
        /usr/bin/grep -Fqx '2|4242' "$CMUX_TEST_IDENTITY_CALL" || exit 98
        test ! -s "$CMUX_TEST_SIGNALS" || exit 97
        test ! -s "$CMUX_TEST_SIGNALED_PIDS" || exit 96
        test ! -e "$CMUX_TEST_POST_TIMEOUT_SNAPSHOT" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root).merging([
                "CMUX_TEST_IDENTITY_CALL": root.appendingPathComponent("identity-call").path,
                "CMUX_TEST_POST_TIMEOUT_SNAPSHOT": root
                    .appendingPathComponent("post-timeout-snapshot").path,
            ]) { _, override in override },
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func ownershipExpansionRetainsReparentedPIDAndRejectsChangedStableIdentity(
        shellPath: String
    ) throws {
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
        test "$(/usr/bin/wc -l < "$CMUX_TEST_OWNED" | /usr/bin/tr -d '[:space:]')" -eq 2 || exit 98
        /usr/bin/grep -Fqx '101 9 11 Thu_Jan_1_00:00:00_1970 S' "$CMUX_TEST_OWNED" || exit 97
        /usr/bin/grep -Fqx '103 1 13 Thu_Jan_1_00:00:00_1970 T' "$CMUX_TEST_OWNED" || exit 97
        ! /usr/bin/grep -Eq '^102 ' "$CMUX_TEST_OWNED" || exit 96

        printf '101 1 11 Thu_Jan_1_00:00:00_1970 S\n' > "$CMUX_TEST_CANDIDATES"
        cmux_ssh_auth_filter_current_processes "$CMUX_TEST_SNAPSHOT" \
          "$CMUX_TEST_CANDIDATES" "$CMUX_TEST_FILTERED" 0 || exit 95
        /usr/bin/grep -Fqx '101 1 11 Thu_Jan_1_00:00:00_1970 S' \
          "$CMUX_TEST_FILTERED" || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CANDIDATES": root.appendingPathComponent("candidates").path,
                "CMUX_TEST_FILTERED": root.appendingPathComponent("filtered").path,
                "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
                "CMUX_TEST_OWNED_NEXT": root.appendingPathComponent("owned.next").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezeRevalidatesPIDImmediatelyBeforeStop(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-prestop-identity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() { : > "$cmux_ssh_auth_owned_groups"; }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() { : > "$1"; }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_identity() {
          printf '1|777|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_auth_identity() { printf '9|99|Thu_Jan_1_00:00:00_1970\n'; }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 2 Thu_Jan_1_00:00:00_1970 S\n' > "$CMUX_TEST_OWNED"
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_freeze_owned_processes || exit 99
        test ! -s "$CMUX_TEST_SIGNALS" || exit 98
        test ! -s "$CMUX_TEST_SIGNALED_PIDS" || exit 97
        test ! -s "$CMUX_TEST_FROZEN" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root),
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezeRejectsChangedPIDIdentityInPostStopSnapshot(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-poststop-identity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() { : > "$cmux_ssh_auth_owned_groups"; }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 9 99 T Thu Jan 1 00:00:00 1970\n' > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_identity() {
          cmux_test_identity_calls=$(/bin/cat "$CMUX_TEST_IDENTITY_CALLS") || return 1
          cmux_test_identity_calls=$((cmux_test_identity_calls + 1))
          printf '%s\n' "$cmux_test_identity_calls" > "$CMUX_TEST_IDENTITY_CALLS" || return 1
          printf '1|2|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() {
          if [ "$*" = '-STOP 101' ] && \
            /usr/bin/grep -Fqx '101 1 2 Thu_Jan_1_00:00:00_1970 S' \
              "$CMUX_TEST_SIGNALED_PIDS"; then
            : > "$CMUX_TEST_RECORDED_BEFORE_STOP"
          fi
          printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"
        }
        printf '0\n' > "$CMUX_TEST_IDENTITY_CALLS"
        printf '101 1 2 Thu_Jan_1_00:00:00_1970 S\n' > "$CMUX_TEST_OWNED"
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        if cmux_ssh_auth_freeze_owned_processes; then exit 99; fi
        test -f "$CMUX_TEST_RECORDED_BEFORE_STOP" || exit 98
        test "$(/bin/cat "$CMUX_TEST_IDENTITY_CALLS")" -eq 1 || exit 97
        /usr/bin/grep -Fqx -- '-STOP 101' "$CMUX_TEST_SIGNALS" || exit 96
        ! /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 95
        test ! -s "$CMUX_TEST_FROZEN" || exit 94
        """

        var environment = freezeIdentityTestEnvironment(root: root)
        environment["CMUX_TEST_IDENTITY_CALLS"] = root.appendingPathComponent("identity-calls").path
        environment["CMUX_TEST_RECORDED_BEFORE_STOP"] = root
            .appendingPathComponent("recorded-before-stop").path
        let result = try runShellCommand(command, environment: environment, shellPath: shellPath)

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezeSignalsValidatedMembersInsteadOfWholeProcessGroup(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-group-stop-journal-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() { : > "$cmux_ssh_auth_owned_groups"; }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 1 777 T Thu Jan 1 00:00:00 1970\n102 1 777 T Thu Jan 1 00:00:00 1970\n' \
            > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\n102 1 777 Thu_Jan_1_00:00:00_1970 S\n' \
          > "$CMUX_TEST_OWNED"
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_freeze_owned_processes || exit 99
        test ! -s "$CMUX_TEST_SIGNALED_GROUPS" || exit 98
        ! /usr/bin/grep -Fq -- '-STOP -- -777' "$CMUX_TEST_SIGNALS" || exit 97
        /usr/bin/grep -Fqx -- '-STOP 101' "$CMUX_TEST_SIGNALS" || exit 96
        /usr/bin/grep -Fqx -- '-STOP 102' "$CMUX_TEST_SIGNALS" || exit 95
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALED_PIDS" | \
          /usr/bin/tr -d '[:space:]')" -eq 2 || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root),
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezeStopsExclusiveGroupBeforeFinalSnapshot(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-exclusive-group-freeze-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() {
          printf '777\n' > "$cmux_ssh_auth_owned_groups"
        }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 1 777 T Thu Jan 1 00:00:00 1970\n102 1 777 T Thu Jan 1 00:00:00 1970\n' \
            > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\n102 1 777 Thu_Jan_1_00:00:00_1970 S\n' \
          > "$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_group=777
        cmux_ssh_auth_group_anchor=101
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_groups="$CMUX_TEST_GROUPS.next"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_freeze_owned_processes || exit 99
        /usr/bin/grep -Fqx -- '-STOP -- -777' "$CMUX_TEST_SIGNALS" || exit 98
        /usr/bin/grep -Fqx \
          '777 101 1 Thu_Jan_1_00:00:00_1970 S' \
          "$CMUX_TEST_SIGNALED_GROUPS" || exit 97
        test ! -s "$CMUX_TEST_SIGNALED_PIDS" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root),
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackResumesMemberJournaledFromPostStopSnapshot(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-poststop-journal-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_select_exclusive_groups() {
          printf '777\n' > "$cmux_ssh_auth_owned_groups"
        }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 1 777 T Thu Jan 1 00:00:00 1970\n102 1 777 T Thu Jan 1 00:00:00 1970\n103 101 777 T Thu Jan 1 00:00:00 1970\n' \
            > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 1; }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_auth_stopped_identity() {
          printf '1|777|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\n102 1 777 Thu_Jan_1_00:00:00_1970 S\n' \
          > "$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_group=777
        cmux_ssh_auth_group_anchor=101
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_groups="$CMUX_TEST_GROUPS.next"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        if cmux_ssh_auth_freeze_owned_processes; then exit 99; fi
        /usr/bin/grep -Fqx \
          '777 103 101 Thu_Jan_1_00:00:00_1970 S' \
          "$CMUX_TEST_SIGNALED_GROUPS" || exit 98
        cmux_ssh_auth_take_process_snapshot_until() {
          printf '103 1 777 T Thu Jan 1 00:00:00 1970\n' > "$1"
        }
        cmux_ssh_auth_resume_signaled_processes || exit 97
        /usr/bin/grep -Fqx -- '-CONT 103' "$CMUX_TEST_SIGNALS" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root).merging([
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
            ]) { _, new in new },
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackFindsStoppedDescendantWhenPostStopSnapshotFails(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-poststop-failure-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_select_exclusive_groups() {
          printf '777\n' > "$cmux_ssh_auth_owned_groups"
        }
        cmux_ssh_auth_take_process_snapshot() { return 1; }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_auth_stopped_identity() {
          printf '1|777|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_auth_take_process_snapshot_until() {
          printf '101 1 777 T Thu Jan 1 00:00:00 1970\n102 1 777 T Thu Jan 1 00:00:00 1970\n103 101 777 T Thu Jan 1 00:00:00 1970\n999 7 777 T Fri Jan 2 00:00:00 1970\n' \
            > "$1"
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\n102 1 777 Thu_Jan_1_00:00:00_1970 S\n' \
          > "$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_group=777
        cmux_ssh_auth_group_anchor=101
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_groups="$CMUX_TEST_GROUPS.next"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        if cmux_ssh_auth_freeze_owned_processes; then exit 99; fi
        cmux_ssh_auth_resume_signaled_processes || exit 98
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" \
          -eq 4 || exit 97
        /usr/bin/grep -Fqx -- '-STOP -- -777' "$CMUX_TEST_SIGNALS" || exit 96
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 95
        /usr/bin/grep -Fqx -- '-CONT 102' "$CMUX_TEST_SIGNALS" || exit 94
        /usr/bin/grep -Fqx -- '-CONT 103' "$CMUX_TEST_SIGNALS" || exit 93
        ! /usr/bin/grep -Fqx -- '-CONT 999' "$CMUX_TEST_SIGNALS" || exit 92
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root).merging([
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
            ]) { _, new in new },
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackResumesExclusiveGroupAfterAnchorExit(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-anchor-exit-rollback-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_now_millis() { printf '1000\\n'; }
        cmux_ssh_auth_select_exclusive_groups() {
          printf '777\\n' > "$cmux_ssh_auth_owned_groups"
        }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 1 777 T Thu Jan 1 00:00:00 1970\\n102 1 777 T Thu Jan 1 00:00:00 1970\\n' \\
            > "$1"
        }
        cmux_ssh_auth_take_process_snapshot_until() {
          # The recorded anchor was killed after STOP. The other member remains
          # stopped and must be sufficient to resume the process group.
          printf '102 1 777 T Thu Jan 1 00:00:00 1970\\n' > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\\n'
        }
        cmux_ssh_auth_stopped_identity() {
          printf '1|777|Thu_Jan_1_00:00:00_1970\\n'
        }
        kill() { printf '%s\\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\\n102 1 777 Thu_Jan_1_00:00:00_1970 S\\n' \\
          > "$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_group=777
        cmux_ssh_auth_group_anchor=101
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_groups="$CMUX_TEST_GROUPS.next"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_freeze_owned_processes || exit 99
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_resume_signaled_processes || exit 98
        /usr/bin/grep -Fqx -- '-CONT 102' "$CMUX_TEST_SIGNALS" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root).merging([
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
            ]) { _, new in new },
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezeAvoidsGroupStopWhenMemberWasAlreadyStopped(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-prestopped-group-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() {
          printf '777\n' > "$cmux_ssh_auth_owned_groups"
        }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 1 777 T Thu Jan 1 00:00:00 1970\n102 1 777 T Thu Jan 1 00:00:00 1970\n' \
            > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\n102 1 777 Thu_Jan_1_00:00:00_1970 T\n' \
          > "$CMUX_TEST_OWNED"
        printf '101 1 777 S Thu Jan 1 00:00:00 1970\n102 1 777 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_owned_group=777
        cmux_ssh_auth_group_anchor=101
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_groups="$CMUX_TEST_GROUPS.next"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_freeze_owned_processes || exit 99
        ! /usr/bin/grep -Fq -- '-STOP -- -777' "$CMUX_TEST_SIGNALS" || exit 98
        /usr/bin/grep -Fqx -- '-STOP 101' "$CMUX_TEST_SIGNALS" || exit 97
        /usr/bin/grep -Fqx -- '-STOP 102' "$CMUX_TEST_SIGNALS" || exit 96
        /usr/bin/grep -Fqx \
          '101 1 777 Thu_Jan_1_00:00:00_1970 S' \
          "$CMUX_TEST_SIGNALED_PIDS" || exit 95
        /usr/bin/grep -Fqx \
          '102 1 777 Thu_Jan_1_00:00:00_1970 T' \
          "$CMUX_TEST_SIGNALED_PIDS" || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root),
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezeRejectsRunningDescendantWithoutGroupSignal(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-exclusive-group-escape-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() {
          printf '777\n' > "$cmux_ssh_auth_owned_groups"
        }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          printf '101 1 777 T Thu Jan 1 00:00:00 1970\n102 101 778 S Thu Jan 1 00:00:00 1970\n' \
            > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() {
          printf '101 1 777 Thu_Jan_1_00:00:00_1970 T\n102 101 778 Thu_Jan_1_00:00:00_1970 S\n' \
            > "$cmux_ssh_auth_owned_processes"
        }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 777 Thu_Jan_1_00:00:00_1970 S\n' > "$CMUX_TEST_OWNED"
        cmux_ssh_auth_owned_group=777
        cmux_ssh_auth_group_anchor=101
        : > "$CMUX_TEST_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_next_owned_groups="$CMUX_TEST_GROUPS.next"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        if cmux_ssh_auth_freeze_owned_processes; then exit 99; fi
        /usr/bin/grep -Fqx -- '-STOP 101' "$CMUX_TEST_SIGNALS" || exit 98
        ! /usr/bin/grep -Fq -- '-STOP -- -' "$CMUX_TEST_SIGNALS" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root),
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func freezeBatchesSharedGroupAboveWriteAheadStopBudget(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-stop-budget-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_deadline_allows_signal() { return 0; }
        cmux_ssh_auth_select_exclusive_groups() { : > "$cmux_ssh_auth_owned_groups"; }
        cmux_ssh_auth_filter_current_processes() { /bin/cp "$2" "$3"; }
        cmux_ssh_auth_order_children_first() { /usr/bin/awk '{ print 0, $0 }' "$1" > "$2"; }
        cmux_ssh_auth_take_process_snapshot() {
          /usr/bin/awk 'BEGIN {
            for (pid = 1000; pid <= 2024; pid += 1) {
              print pid, 1, 777, "T Thu Jan 1 00:00:00 1970"
            }
          }' > "$1"
        }
        cmux_ssh_auth_expand_owned_processes() { return 0; }
        cmux_ssh_auth_stable_identity() {
          printf '777|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        : > "$CMUX_TEST_GROUPS"
        /usr/bin/awk 'BEGIN {
          for (pid = 1000; pid <= 2024; pid += 1) {
            print pid, 1, 777, "Thu_Jan_1_00:00:00_1970", "S"
          }
        }' > "$CMUX_TEST_OWNED"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_PROCESS_SNAPSHOT"
        cmux_ssh_auth_poststop_snapshot="$CMUX_TEST_POSTSTOP_SNAPSHOT"
        cmux_ssh_auth_owned_processes="$CMUX_TEST_OWNED"
        cmux_ssh_auth_next_owned_processes="$CMUX_TEST_OWNED_NEXT"
        cmux_ssh_auth_owned_groups="$CMUX_TEST_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_ordered_processes="$CMUX_TEST_ORDERED"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_freeze_owned_processes || exit 99
        test ! -s "$CMUX_TEST_SIGNALED_GROUPS" || exit 98
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALED_PIDS" | \
          /usr/bin/tr -d '[:space:]')" -eq 32 || exit 97
        test "$(/usr/bin/wc -l < "$CMUX_TEST_FROZEN" | \
          /usr/bin/tr -d '[:space:]')" -eq 32 || exit 96
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | \
          /usr/bin/tr -d '[:space:]')" -eq 32 || exit 95
        ! /usr/bin/grep -Fq -- '-STOP -- -' "$CMUX_TEST_SIGNALS" || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: freezeIdentityTestEnvironment(root: root),
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func resumeSignaledProcessesRequiresDurableIdentity(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-resume-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          /bin/cp "$CMUX_TEST_CURRENT" "$1"
        }
        cmux_ssh_auth_stable_identity() {
          case "$1" in
            101|103) printf '2|Thu_Jan_1_00:00:00_1970\n' ;;
            *) return 1 ;;
          esac
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 7 2 T Thu Jan 1 00:00:00 1970\n102 9 99 T Thu Jan 1 00:00:00 1970\n103 8 2 T Thu Jan 1 00:00:00 1970\n104 9 99 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_CURRENT"
        printf '101 1 2 Thu_Jan_1_00:00:00_1970\n102 1 2 Thu_Jan_1_00:00:00_1970\n103\n104\n' \
          > "$CMUX_TEST_SIGNALED_PIDS"
        # The exact and legacy records retain the pre-crash parent, while the
        # current processes have been reparented without changing stable identity.
        printf '103 1 2 Thu_Jan_1_00:00:00_1970 T\n' > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_resume_signaled_processes
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" -eq 2 || exit 99
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 98
        /usr/bin/grep -Fqx -- '-CONT 103' "$CMUX_TEST_SIGNALS" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func stableIdentityUsesKernelStartTimestamp(shellPath: String) throws {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let pid = getpid()
        let actualSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        #expect(actualSize == expectedSize)

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-kernel-identity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_stable_identity "$CMUX_TEST_PID" > "$CMUX_TEST_IDENTITY"
        """
        let identityURL = root.appendingPathComponent("identity")
        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_IDENTITY": identityURL.path,
                "CMUX_TEST_PID": String(pid),
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        let actual = try String(contentsOf: identityURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = "\(info.pbi_pgid)|K_\(info.pbi_start_tvsec)_\(info.pbi_start_tvusec)"
        #expect(actual == expected)
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func publishesWorkerIdentityUsingKernelProcessLayout(shellPath: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-worker-kernel-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownerURL = root.appendingPathComponent("owner")
        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_publish_current_worker "$CMUX_TEST_OWNER"
        cmux_ssh_auth_parse_recorded_process "$CMUX_TEST_OWNER"
        """
        let result = try runShellCommand(
            command,
            environment: ["CMUX_TEST_OWNER": ownerURL.path],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func cleanupOwnerReadFailureDoesNotProveAbandonment(shellPath: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-cleanup-owner-read-failure-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try FileManager.default.createDirectory(
            at: groupDirectory.appendingPathComponent("cleanup.lock"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        : > "$CMUX_TEST_GROUP/cancel"
        printf '%s|1|K_1_1\\n' "$$" > "$CMUX_TEST_GROUP/cleanup.owner"
        cmux_ssh_auth_stable_identity() { return 1; }
        if cmux_ssh_auth_group_cleanup_is_abandoned "$CMUX_TEST_GROUP"; then exit 97; fi
        """
        let result = try runShellCommand(
            command,
            environment: ["CMUX_TEST_GROUP": groupDirectory.path],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackDoesNotResumeProcessStoppedBeforeCleanup(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-preserve-prestopped-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          /bin/cp "$CMUX_TEST_CURRENT" "$1"
        }
        cmux_ssh_auth_stable_identity() {
          printf '11|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 11 T Thu Jan 1 00:00:00 1970\n102 1 12 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_CURRENT"
        printf '101 1 11 Thu_Jan_1_00:00:00_1970 S\n102 1 12 Thu_Jan_1_00:00:00_1970 T\n' \
          > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_resume_signaled_processes || exit 99
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" \
          -eq 1 || exit 98
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 97
        ! /usr/bin/grep -Fqx -- '-CONT 102' "$CMUX_TEST_SIGNALS" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackRevalidatesStoppedIdentityImmediatelyBeforeResume(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-resume-revalidation-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          /bin/cp "$CMUX_TEST_CURRENT" "$1"
        }
        cmux_ssh_auth_stable_identity() {
          printf '%s\n' "$1" >> "$CMUX_TEST_IDENTITY_CALLS"
          case "$1" in
            101) printf '11|Thu_Jan_1_00:00:00_1970\n' ;;
            102) printf '12|Fri_Jan_2_00:00:00_1970\n' ;;
            *) return 1 ;;
          esac
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 11 T Thu Jan 1 00:00:00 1970\n102 1 12 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_CURRENT"
        printf '101 1 11 Thu_Jan_1_00:00:00_1970 S\n102 1 12 Thu_Jan_1_00:00:00_1970 S\n' \
          > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_IDENTITY_CALLS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_resume_signaled_processes || exit 99
        test "$(/usr/bin/wc -l < "$CMUX_TEST_IDENTITY_CALLS")" -eq 2 || exit 98
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS")" -eq 1 || exit 97
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 96
        ! /usr/bin/grep -Fqx -- '-CONT 102' "$CMUX_TEST_SIGNALS" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_IDENTITY_CALLS": root.appendingPathComponent("identity-calls").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func resumeSignaledGroupsRequiresDurableMemberIdentity(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-resume-group-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          /bin/cp "$CMUX_TEST_CURRENT" "$1"
        }
        cmux_ssh_auth_stable_identity() {
          case "$1" in
            101) printf '11|Thu_Jan_1_00:00:00_1970\n' ;;
            103) printf '13|Thu_Jan_1_00:00:00_1970\n' ;;
            *) return 1 ;;
          esac
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 7 11 T Thu Jan 1 00:00:00 1970\n102 9 99 T Thu Jan 1 00:00:00 1970\n103 8 13 T Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_CURRENT"
        printf '11 101 1 Thu_Jan_1_00:00:00_1970\n12 102 1 Thu_Jan_1_00:00:00_1970\n13\n14\n' \
          > "$CMUX_TEST_SIGNALED_GROUPS"
        # The recorded members were reparented after cleanup crashed. Their
        # stable PID, process-group, and start-time identities still match.
        printf '103 1 13 Thu_Jan_1_00:00:00_1970 T\n' > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_resume_signaled_processes
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" \
          -eq 2 || exit 99
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 98
        /usr/bin/grep -Fqx -- '-CONT 103' "$CMUX_TEST_SIGNALS" || exit 97
        ! /usr/bin/grep -Fqx -- '-CONT -- -12' "$CMUX_TEST_SIGNALS" || exit 96
        ! /usr/bin/grep -Fqx -- '-CONT -- -14' "$CMUX_TEST_SIGNALS" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackResumesValidatedMemberWithoutSignalingLaterGroupJoiner(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-resume-later-group-joiner-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          /bin/cp "$CMUX_TEST_CURRENT" "$1"
        }
        cmux_ssh_auth_stable_identity() {
          printf '11|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 7 11 T Thu Jan 1 00:00:00 1970\n999 7 11 T Fri Jan 2 00:00:00 1970\n' \
          > "$CMUX_TEST_CURRENT"
        printf '11 101 1 Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_resume_signaled_processes || exit 99
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" \
          -eq 1 || exit 98
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 97
        ! /usr/bin/grep -Fqx -- '-CONT -- -11' "$CMUX_TEST_SIGNALS" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackResumesEveryJournaledStopAfterTerminationDeadline(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-expired-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_signal() { return 1; }
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          /bin/cp "$CMUX_TEST_CURRENT" "$1"
        }
        cmux_ssh_auth_stable_identity() {
          case "$1" in
            101) printf '11|Thu_Jan_1_00:00:00_1970\n' ;;
            102) printf '12|Thu_Jan_1_00:00:00_1970\n' ;;
            *) return 1 ;;
          esac
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '101 1 11 S Thu Jan 1 00:00:00 1970\n102 1 12 S Thu Jan 1 00:00:00 1970\n' \
          > "$CMUX_TEST_CURRENT"
        printf '11 101 1 Thu_Jan_1_00:00:00_1970\n12 102 1 Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_TEST_SIGNALED_GROUPS"
        printf '101 1 11 Thu_Jan_1_00:00:00_1970\n102 1 12 Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_deadline_millis=1
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_resume_signaled_processes || exit 99
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | /usr/bin/tr -d '[:space:]')" -eq 2 \
          || exit 98
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 97
        /usr/bin/grep -Fqx -- '-CONT 102' "$CMUX_TEST_SIGNALS" || exit 96
        ! /usr/bin/grep -Fq -- '-CONT -- -' "$CMUX_TEST_SIGNALS" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackUsesOneSnapshotAndResumesValidatedMembers(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-rollback-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let started = "Thu_Jan_1_00:00:00_1970"
        let processIDs = 101...1124
        let groupJournal = processIDs
            .map { "11 \($0) 1 \(started)" }
            .joined(separator: "\n") + "\n"
        let currentSnapshot = processIDs
            .map { "\($0) 7 11 T Thu Jan 1 00:00:00 1970" }
            .joined(separator: "\n") + "\n"
        try groupJournal.write(
            to: root.appendingPathComponent("signaled.groups"),
            atomically: true,
            encoding: .utf8
        )
        try currentSnapshot.write(
            to: root.appendingPathComponent("current"),
            atomically: true,
            encoding: .utf8
        )

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          printf x >> "$CMUX_TEST_SNAPSHOT_CALLS"
          /bin/cp "$CMUX_TEST_CURRENT" "$1"
        }
        cmux_ssh_auth_stable_identity() {
          printf x >> "$CMUX_TEST_IDENTITY_CALLS"
          printf '11|Thu_Jan_1_00:00:00_1970\n'
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_FROZEN"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_resume_signaled_processes || exit 99
        test "$(/usr/bin/wc -c < "$CMUX_TEST_SNAPSHOT_CALLS" | \\
          /usr/bin/tr -d '[:space:]')" -eq 1 || exit 98
        test "$(/usr/bin/wc -c < "$CMUX_TEST_IDENTITY_CALLS")" -eq 1024 || exit 97
        test "$(/usr/bin/wc -l < "$CMUX_TEST_SIGNALS" | \\
          /usr/bin/tr -d '[:space:]')" -eq 1024 || exit 96
        /usr/bin/grep -Fqx -- '-CONT 101' "$CMUX_TEST_SIGNALS" || exit 95
        /usr/bin/grep -Fqx -- '-CONT 1124' "$CMUX_TEST_SIGNALS" || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CURRENT": root.appendingPathComponent("current").path,
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_IDENTITY_CALLS": root.appendingPathComponent("identity-calls").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
                "CMUX_TEST_SNAPSHOT_CALLS": root.appendingPathComponent("snapshot-calls").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func rollbackCannotExtendPastSafetyMargin(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-rollback-deadline-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1500\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          : > "$CMUX_TEST_SNAPSHOT_CALLED"
          return 1
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        printf '11 101 1 Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_TEST_SIGNALED_GROUPS"
        : > "$CMUX_TEST_SIGNALED_PIDS"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_auth_hard_deadline_millis=1000
        cmux_ssh_auth_process_snapshot="$CMUX_TEST_SNAPSHOT"
        cmux_ssh_auth_resume_groups="$CMUX_TEST_RESUME_GROUPS"
        cmux_ssh_auth_individual_processes="$CMUX_TEST_INDIVIDUALS"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        if cmux_ssh_auth_resume_signaled_processes; then exit 99; fi
        test ! -e "$CMUX_TEST_SNAPSHOT_CALLED" || exit 98
        test ! -s "$CMUX_TEST_SIGNALS" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
                "CMUX_TEST_RESUME_GROUPS": root.appendingPathComponent("groups.resume").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
                "CMUX_TEST_SNAPSHOT": root.appendingPathComponent("snapshot").path,
                "CMUX_TEST_SNAPSHOT_CALLED": root.appendingPathComponent("snapshot-called").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func unpublishedRollbackFailurePreservesDurableJournal(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        let statePathFile = root.appendingPathComponent("state-path")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_run_cleanup_transactions() {
          printf '%s\n' "$cmux_ssh_auth_tree_state" > "$CMUX_TEST_STATE_PATH"
          printf '101 1 777 Thu_Jan_1_00:00:00_1970\n' \
            > "$cmux_ssh_auth_signaled_processes"
          return 1
        }
        cmux_ssh_auth_resume_signaled_processes() { return 1; }
        if cmux_ssh_terminate_unpublished_auth_process_tree \
          101 1 777 Thu_Jan_1_00:00:00_1970; then exit 99; fi
        cmux_test_state=$(/bin/cat "$CMUX_TEST_STATE_PATH") || exit 98
        test -d "$cmux_test_state" || exit 97
        test -f "$cmux_test_state/rollback-only" || exit 96
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970' \
          "$cmux_test_state/signaled.pids" || exit 95
        /usr/bin/grep -Fqx "$cmux_test_state" \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.0" || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_STATE_PATH": statePathFile.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func unpublishedCleanupFailurePreservesOwnershipWithoutStopJournal(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-ownership-\(UUID().uuidString)",
            isDirectory: true
        )
        let statePathFile = root.appendingPathComponent("state-path")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_run_cleanup_transactions() {
          printf '%s\n' "$cmux_ssh_auth_tree_state" > "$CMUX_TEST_STATE_PATH"
          return 1
        }
        cmux_ssh_auth_resume_signaled_processes() { return 0; }
        if cmux_ssh_terminate_unpublished_auth_process_tree \
          101 1 777 Thu_Jan_1_00:00:00_1970; then exit 99; fi
        cmux_test_state=$(/bin/cat "$CMUX_TEST_STATE_PATH") || exit 98
        test -d "$cmux_test_state" || exit 97
        test -f "$cmux_test_state/rollback-only" || exit 96
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970 R' \
          "$cmux_test_state/owned" || exit 95
        /usr/bin/grep -Fqx "$cmux_test_state" \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.0" || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_STATE_PATH": statePathFile.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func unpublishedFallbackFailurePublishesDurableOwnership(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-setup-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.preallocated",
            isDirectory: true
        )
        let signals = root.appendingPathComponent("signals")
        let enqueuedGroup = root.appendingPathComponent("enqueued-group")
        let processSnapshot = root.appendingPathComponent("processes")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          /bin/cp "$CMUX_TEST_PROCESS_SNAPSHOT" "$1"
        }
        cmux_ssh_auth_identity() {
          test "$1" = 101 || return 1
          printf '1|777|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_auth_publish_current_worker() { return 1; }
        cmux_ssh_terminate_owned_auth_group() { :; }
        cmux_ssh_auth_force_unpublished_process_tree() { return 1; }
        cmux_ssh_auth_recovery_enqueue() {
          printf '%s\n' "$1" > "$CMUX_TEST_ENQUEUED_GROUP"
        }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        CMUX_SSH_AUTH_GROUP_DIR="$CMUX_TEST_GROUP_DIR"
        export CMUX_SSH_AUTH_GROUP_DIR
        printf '101 1 777 S Thu Jan 1 00:00:00 1970\n202 101 778 S Fri Jan 2 00:00:00 1970\n' \
          > "$CMUX_TEST_PROCESS_SNAPSHOT"
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_terminate_auth_process_tree 101 1
        if /usr/bin/grep -Fqx -- '-KILL 101' "$CMUX_TEST_SIGNALS"; then exit 99; fi
        test -f "$CMUX_SSH_AUTH_GROUP_DIR/rollback-only" || exit 98
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970' \
          "$CMUX_SSH_AUTH_GROUP_DIR/unpublished.root" || exit 97
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970 S' \
          "$CMUX_SSH_AUTH_GROUP_DIR/owned" || exit 96
        /usr/bin/grep -Fqx '202 101 778 Fri_Jan_2_00:00:00_1970 S' \
          "$CMUX_SSH_AUTH_GROUP_DIR/owned" || exit 94
        /usr/bin/grep -Fqx "$CMUX_SSH_AUTH_GROUP_DIR" \
          "$CMUX_TEST_ENQUEUED_GROUP" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_ENQUEUED_GROUP": enqueuedGroup.path,
                "CMUX_TEST_PROCESS_SNAPSHOT": processSnapshot.path,
                "CMUX_TEST_SIGNALS": signals.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func failedDurableFallbackRetriesInProcessCleanup(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-handoff-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.preallocated",
            isDirectory: true
        )
        let attempts = root.appendingPathComponent("attempts")
        let signals = root.appendingPathComponent("signals")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_test_force_attempts=0
        cmux_ssh_auth_identity() {
          test "$1" = 101 || return 1
          if [ "$cmux_test_force_attempts" -ge 3 ]; then return 1; fi
          printf '1|777|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_terminate_unpublished_auth_process_tree() { return 1; }
        cmux_ssh_terminate_owned_auth_group() { :; }
        cmux_ssh_auth_force_unpublished_process_tree() {
          cmux_test_force_attempts=$((cmux_test_force_attempts + 1))
          printf '%s\n' "$cmux_test_force_attempts" > "$CMUX_TEST_ATTEMPTS"
          test "$cmux_test_force_attempts" -ge 3
        }
        cmux_ssh_auth_recovery_enqueue() { return 1; }
        kill() { printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"; }
        CMUX_SSH_AUTH_GROUP_DIR="$CMUX_TEST_GROUP_DIR"
        export CMUX_SSH_AUTH_GROUP_DIR
        : > "$CMUX_TEST_SIGNALS"
        cmux_ssh_terminate_auth_process_tree 101 1
        test "$(/bin/cat "$CMUX_TEST_ATTEMPTS")" -eq 3 || exit 99
        test ! -s "$CMUX_TEST_SIGNALS" || exit 98
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_ATTEMPTS": attempts.path,
                "CMUX_TEST_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_SIGNALS": signals.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func unpublishedAllocationFailureStillKillsDescendants(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-state-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.preallocated",
            isDirectory: true
        )
        let leafPIDFile = root.appendingPathComponent("leaf.pid")
        let leafStateFile = root.appendingPathComponent("leaf.state")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_create_group_dir() { return 1; }
        cmux_ssh_terminate_owned_auth_group() { :; }
        (
          trap '' HUP INT TERM
          ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
          printf '%s\n' "$!" > "$CMUX_TEST_LEAF_PID"
          while :; do /bin/sleep 30; done
        ) &
        cmux_test_root_pid=$!
        trap '/bin/kill -KILL "$cmux_test_root_pid" >/dev/null 2>&1 || true; if [ -s "$CMUX_TEST_LEAF_PID" ]; then /bin/kill -KILL "$(/bin/cat "$CMUX_TEST_LEAF_PID")" >/dev/null 2>&1 || true; fi' EXIT
        cmux_test_ready_attempt=0
        while [ ! -s "$CMUX_TEST_LEAF_PID" ] && \
          [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -s "$CMUX_TEST_LEAF_PID" || exit 99
        cmux_ssh_terminate_auth_process_tree "$cmux_test_root_pid" "$$"
        wait "$cmux_test_root_pid" 2>/dev/null || true
        /usr/bin/env LC_ALL=C LANG=C /bin/ps -o state= \
          -p "$(/bin/cat "$CMUX_TEST_LEAF_PID")" \
          > "$CMUX_TEST_LEAF_STATE" 2>/dev/null || true
        trap - EXIT
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_LEAF_PID": leafPIDFile.path,
                "CMUX_TEST_LEAF_STATE": leafStateFile.path,
                "CMUX_SSH_AUTH_GROUP_DIR": "",
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )
        let leafPID = try #require(Int32(
            String(contentsOf: leafPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(leafPID, SIGKILL) }
        let leafState = try String(contentsOf: leafStateFile, encoding: .utf8)

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        #expect(Darwin.kill(leafPID, 0) != 0)
        #expect(leafState.isEmpty, "State-creation fallback left a descendant: \(leafState)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func unpublishedCleanupFreezesRootBeforePublisherSetup(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-prefreeze-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.preallocated",
            isDirectory: true
        )
        let leafPIDFile = root.appendingPathComponent("leaf-pid")
        let releaseFile = root.appendingPathComponent("release")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        (
          trap '' HUP INT TERM
          ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
          printf '%s\n' "$!" > "$CMUX_TEST_LEAF_PID"
          while [ ! -e "$CMUX_TEST_RELEASE" ]; do /bin/sleep 0.01; done
        ) &
        cmux_test_root_pid=$!
        trap '/bin/kill -KILL "$cmux_test_root_pid" >/dev/null 2>&1 || true; if [ -s "$CMUX_TEST_LEAF_PID" ]; then /bin/kill -KILL "$(/bin/cat "$CMUX_TEST_LEAF_PID")" >/dev/null 2>&1 || true; fi' EXIT
        cmux_test_ready_attempt=0
        while [ ! -s "$CMUX_TEST_LEAF_PID" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -s "$CMUX_TEST_LEAF_PID" || exit 99
        cmux_test_root_identity=$(cmux_ssh_auth_identity "$cmux_test_root_pid") || exit 98
        cmux_test_root_parent=${cmux_test_root_identity%%|*}
        cmux_test_root_remainder=${cmux_test_root_identity#*|}
        cmux_test_root_group=${cmux_test_root_remainder%%|*}
        cmux_test_root_started=${cmux_test_root_remainder#*|}
        cmux_ssh_auth_publish_current_worker() {
          : > "$CMUX_TEST_RELEASE"
          return 0
        }
        CMUX_SSH_AUTH_GROUP_DIR="$CMUX_TEST_GROUP_DIR"
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_terminate_unpublished_auth_process_tree \
          "$cmux_test_root_pid" "$cmux_test_root_parent" \
          "$cmux_test_root_group" "$cmux_test_root_started" || exit 97
        wait "$cmux_test_root_pid" 2>/dev/null || true
        cmux_test_leaf_state=$(/usr/bin/env LC_ALL=C LANG=C /bin/ps -o state= \
          -p "$(/bin/cat "$CMUX_TEST_LEAF_PID")" 2>/dev/null | \
          /usr/bin/tr -d '[:space:]')
        case "$cmux_test_leaf_state" in ''|Z*) ;; *) exit 96 ;; esac
        trap - EXIT
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_LEAF_PID": leafPIDFile.path,
                "CMUX_TEST_RELEASE": releaseFile.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func unpublishedCleanupUsesPreallocatedDurableGroupWhenAllocationFails(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-preallocated-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.preallocated",
            isDirectory: true
        )
        let enqueuedGroup = root.appendingPathComponent("enqueued-group")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_create_group_dir() { return 1; }
        cmux_ssh_auth_run_cleanup_transactions() { return 1; }
        cmux_ssh_auth_resume_signaled_processes() { return 0; }
        cmux_ssh_auth_recovery_enqueue() {
          printf '%s\n' "$1" > "$CMUX_TEST_ENQUEUED_GROUP"
        }
        CMUX_SSH_AUTH_GROUP_DIR="$CMUX_TEST_GROUP_DIR"
        export CMUX_SSH_AUTH_GROUP_DIR
        if cmux_ssh_terminate_unpublished_auth_process_tree \
          101 1 777 Thu_Jan_1_00:00:00_1970; then exit 99; fi
        test -f "$CMUX_SSH_AUTH_GROUP_DIR/rollback-only" || exit 98
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970' \
          "$CMUX_SSH_AUTH_GROUP_DIR/unpublished.root" || exit 97
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970 R' \
          "$CMUX_SSH_AUTH_GROUP_DIR/owned" || exit 96
        /usr/bin/grep -Fqx "$CMUX_SSH_AUTH_GROUP_DIR" \
          "$CMUX_TEST_ENQUEUED_GROUP" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_ENQUEUED_GROUP": enqueuedGroup.path,
                "CMUX_TEST_GROUP_DIR": groupDirectory.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func unpublishedCleanupPreservesConcurrentPublishedIdentity(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-publication-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.preallocated",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_run_cleanup_transactions() {
          printf '202|888|Thu_Jan_1_00:00:00_1970\n' \
            > "$cmux_ssh_auth_tree_state/identity"
        }
        CMUX_SSH_AUTH_GROUP_DIR="$CMUX_TEST_GROUP_DIR"
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_terminate_unpublished_auth_process_tree \
          101 1 777 Thu_Jan_1_00:00:00_1970 || exit 99
        /usr/bin/grep -Fqx '202|888|Thu_Jan_1_00:00:00_1970' \
          "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 98
        test ! -e "$CMUX_SSH_AUTH_GROUP_DIR/rollback-only" || exit 97
        test ! -e "$CMUX_SSH_AUTH_GROUP_DIR/unpublished.root" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_GROUP_DIR": groupDirectory.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func authenticationProcessWaitHasBoundedFailure(
        shellPath: String
    ) throws {
        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
        cmux_test_auth_pid=$!
        trap '/bin/kill -KILL "$cmux_test_auth_pid" >/dev/null 2>&1 || true' EXIT
        cmux_ssh_wait_for_auth_process_exit "$cmux_test_auth_pid"
        cmux_test_wait_status=$?
        test "$cmux_test_wait_status" -eq 1 || exit 99
        /bin/kill -0 "$cmux_test_auth_pid" 2>/dev/null || exit 98
        /bin/kill -KILL "$cmux_test_auth_pid" >/dev/null 2>&1 || exit 97
        wait "$cmux_test_auth_pid" 2>/dev/null || true
        trap - EXIT
        """

        let result = try runShellCommand(command, shellPath: shellPath)

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySweepCompletesPreservedUnpublishedOwnership(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-cleanup-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.cleanup-test",
            isDirectory: true
        )
        let cleanupMarker = root.appendingPathComponent("cleanup-ran")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try Data().write(to: groupDirectory.appendingPathComponent("rollback-only"))
        try "101 1 777 Thu_Jan_1_00:00:00_1970\n".write(
            to: groupDirectory.appendingPathComponent("unpublished.root"),
            atomically: true,
            encoding: .utf8
        )
        try "101 1 777 Thu_Jan_1_00:00:00_1970 R\n".write(
            to: groupDirectory.appendingPathComponent("owned"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_resume_signaled_processes() { return 0; }
        cmux_ssh_auth_run_cleanup_transactions() {
          : > "$CMUX_TEST_CLEANUP_RAN"
          : > "$cmux_ssh_auth_owned_processes"
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_GROUP_DIR" || exit 99
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        test -e "$CMUX_TEST_CLEANUP_RAN" || exit 97
        test ! -d "$CMUX_TEST_GROUP_DIR" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CLEANUP_RAN": cleanupMarker.path,
                "CMUX_TEST_GROUP_DIR": groupDirectory.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySweepResumesPreservedUnpublishedJournal(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-unpublished-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.rollback-test",
            isDirectory: true
        )
        let recoveredMarker = root.appendingPathComponent("recovered")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try Data().write(to: groupDirectory.appendingPathComponent("rollback-only"))
        try "101 1 777 Thu_Jan_1_00:00:00_1970\n".write(
            to: groupDirectory.appendingPathComponent("unpublished.root"),
            atomically: true,
            encoding: .utf8
        )
        try "101 1 777 Thu_Jan_1_00:00:00_1970 R\n".write(
            to: groupDirectory.appendingPathComponent("owned"),
            atomically: true,
            encoding: .utf8
        )
        try "101 1 777 Thu_Jan_1_00:00:00_1970\n".write(
            to: groupDirectory.appendingPathComponent("signaled.pids"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_resume_signaled_processes() {
          /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970' \
            "$cmux_ssh_auth_signaled_processes" || return 1
          : > "$CMUX_TEST_RECOVERED"
        }
        cmux_ssh_auth_run_cleanup_transactions() {
          : > "$cmux_ssh_auth_owned_processes"
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_GROUP_DIR" || exit 99
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        test -e "$CMUX_TEST_RECOVERED" || exit 97
        test ! -d "$CMUX_TEST_GROUP_DIR" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_RECOVERED": recoveredMarker.path,
                "TMPDIR": root.path,
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
    func liveReparentedReaperRetainsItsOwnerLock(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-reparented-reaper-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let reaperPIDFile = root.appendingPathComponent("reaper.pid")
        let initialParentFile = root.appendingPathComponent("reaper.parent")
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
        cmux_ssh_terminate_owned_auth_group() { return 1; }
        cmux_test_launch_and_exit() (
          cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
          test "${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}" = 1 || exit 99
          cmux_test_reaper_pid=$!
          cmux_test_reaper_identity=$(cmux_ssh_auth_identity "$cmux_test_reaper_pid") || exit 98
          printf '%s\n' "$cmux_test_reaper_pid" > "$CMUX_TEST_REAPER_PID" || exit 97
          printf '%s\n' "${cmux_test_reaper_identity%%|*}" > "$CMUX_TEST_REAPER_PARENT" || exit 96
        )
        cmux_test_launch_and_exit || exit 95
        cmux_test_reaper_pid=$(/bin/cat "$CMUX_TEST_REAPER_PID") || exit 94
        cmux_test_initial_parent=$(/bin/cat "$CMUX_TEST_REAPER_PARENT") || exit 93
        trap '/bin/kill -KILL "$cmux_test_reaper_pid" >/dev/null 2>&1 || true' EXIT
        cmux_test_reparent_attempt=0
        while [ "$cmux_test_reparent_attempt" -lt 100 ]; do
          cmux_test_current_identity=$(cmux_ssh_auth_identity "$cmux_test_reaper_pid")
          cmux_test_current_parent=${cmux_test_current_identity%%|*}
          if [ -n "$cmux_test_current_identity" ] && \
            [ "$cmux_test_current_parent" != "$cmux_test_initial_parent" ]; then break; fi
          /bin/sleep 0.01
          cmux_test_reparent_attempt=$((cmux_test_reparent_attempt + 1))
        done
        test "$cmux_test_reparent_attempt" -lt 100 || exit 92
        /bin/kill -0 "$cmux_test_reaper_pid" 2>/dev/null || exit 91
        if cmux_ssh_auth_reclaim_stale_reaper_lock \
          "$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock"; then exit 90; fi
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock/owner" || exit 89
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_REAPER_PARENT": initialParentFile.path,
                "CMUX_TEST_REAPER_PID": reaperPIDFile.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoveryReaperUsesLiveWorkerAfterParentShellExits(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-worker-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let readyFile = root.appendingPathComponent("ready")
        let releaseFile = root.appendingPathComponent("release")
        let resultFile = root.appendingPathComponent("result")
        let workerPIDFile = root.appendingPathComponent("worker.pid")
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
          /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        }
        cmux_test_delayed_recovery() (
          trap '' HUP INT TERM
          /bin/sh -c 'printf "%s\\n" "$PPID" > "$1"' \
            cmux-worker "$CMUX_TEST_WORKER_PID" || exit 99
          : > "$CMUX_TEST_READY" || exit 98
          cmux_test_release_attempt=0
          while [ ! -e "$CMUX_TEST_RELEASE" ] && \
            [ "$cmux_test_release_attempt" -lt 500 ]; do
            /bin/sleep 0.01
            cmux_test_release_attempt=$((cmux_test_release_attempt + 1))
          done
          test -e "$CMUX_TEST_RELEASE" || exit 97
          cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
          printf '%s\n' "${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}" > "$CMUX_TEST_RESULT"
          if [ "${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}" = 1 ]; then
            wait "$cmux_ssh_auth_reaper_pid"
          fi
        )
        cmux_test_delayed_recovery </dev/null >/dev/null 2>&1 &
        while :; do /bin/sleep 1; done
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
            "CMUX_TEST_READY": readyFile.path,
            "CMUX_TEST_RELEASE": releaseFile.path,
            "CMUX_TEST_RESULT": resultFile.path,
            "CMUX_TEST_WORKER_PID": workerPIDFile.path,
            "TMPDIR": root.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        let readyDeadline = Date.now.addingTimeInterval(5)
        while !fileManager.fileExists(atPath: readyFile.path), Date.now < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(fileManager.fileExists(atPath: readyFile.path))
        let workerPID = try #require(Int32(
            String(contentsOf: workerPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(workerPID, SIGKILL) }

        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        try Data().write(to: releaseFile)

        let resultDeadline = Date.now.addingTimeInterval(5)
        while !fileManager.fileExists(atPath: resultFile.path), Date.now < resultDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let launched = try String(contentsOf: resultFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(launched == "1")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func activeReaperLimitIsSharedAcrossSSHStartups(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-reaper-limit-\(UUID().uuidString)", isDirectory: true)
        let groupRoot = root.appendingPathComponent("groups", isDirectory: true)
        let resultRoot = root.appendingPathComponent("results", isDirectory: true)
        try fileManager.createDirectory(at: groupRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resultRoot, withIntermediateDirectories: true)
        for index in 0..<12 {
            let groupDirectory = groupRoot.appendingPathComponent("group.\(index)", isDirectory: true)
            try createSecureGroupDirectory(at: groupDirectory)
            try "anchor|group|started\n".write(
                to: groupDirectory.appendingPathComponent("identity"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_terminate_owned_auth_group() {
          while [ ! -e "$CMUX_TEST_RELEASE" ]; do /bin/sleep 0.01; done
          /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        }
        cmux_test_launch() {
          cmux_test_group="$1"
          cmux_test_result="$2"
          (
            CMUX_SSH_AUTH_GROUP_DIR="$cmux_test_group"
            export CMUX_SSH_AUTH_GROUP_DIR
            cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
            cmux_test_launched="${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}"
            printf '%s\n' "$cmux_test_launched" > "$cmux_test_result"
            if [ "$cmux_test_launched" = 1 ]; then
              wait "$cmux_ssh_auth_reaper_pid"
            fi
          ) &
          CMUX_TEST_LAUNCHER_PID=$!
        }
        cmux_test_index=0
        for cmux_test_group in "$CMUX_TEST_GROUP_ROOT"/group.*; do
          cmux_test_result="$CMUX_TEST_RESULT_ROOT/$cmux_test_index"
          cmux_test_launch "$cmux_test_group" "$cmux_test_result"
          cmux_test_result_attempt=0
          while [ ! -s "$cmux_test_result" ] && \
            [ "$cmux_test_result_attempt" -lt 500 ]; do
            /bin/sleep 0.01
            cmux_test_result_attempt=$((cmux_test_result_attempt + 1))
          done
          if [ ! -s "$cmux_test_result" ]; then
            : > "$CMUX_TEST_RELEASE"
            wait
            exit 99
          fi
          cmux_test_index=$((cmux_test_index + 1))
        done
        cmux_test_launched_count=0
        for cmux_test_result in "$CMUX_TEST_RESULT_ROOT"/*; do
          cmux_test_launched_count=$((
            cmux_test_launched_count + $(/bin/cat "$cmux_test_result")
          ))
        done
        : > "$CMUX_TEST_RELEASE"
        wait || exit 98
        test "$cmux_test_launched_count" -eq 8 || exit 97
        cmux_test_active_slots=$(/usr/bin/find \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)" \
            -type d -name 'active.*' -print 2>/dev/null)
        test -z "$cmux_test_active_slots" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_GROUP_ROOT": groupRoot.path,
                "CMUX_TEST_RELEASE": root.appendingPathComponent("release").path,
                "CMUX_TEST_RESULT_ROOT": resultRoot.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func concurrentReaperLaunchKeepsLiveLockOwnedByCreator(
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
        cmux_ssh_terminate_owned_auth_group() {
          if /bin/mkdir "$CMUX_TEST_FIRST_REAPER_GATE" 2>/dev/null; then
            : > "$CMUX_TEST_FIRST_READY"
            cmux_test_release_attempt=0
            while [ ! -e "$CMUX_TEST_RELEASE_FIRST" ] && \
              [ "$cmux_test_release_attempt" -lt 500 ]; do
              /bin/sleep 0.01
              cmux_test_release_attempt=$((cmux_test_release_attempt + 1))
            done
            test -e "$CMUX_TEST_RELEASE_FIRST" || return 1
          fi
          return 1
        }
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
                "CMUX_TEST_FIRST_REAPER_GATE": root.appendingPathComponent("first-gate").path,
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

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func orphanedReaperCannotAdoptReplacementOwner(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-reaper-generation-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let firstLauncherScript = root.appendingPathComponent("first-launcher.sh")
        let firstIdentityCallerPIDFile = root.appendingPathComponent("first-identity-caller.pid")
        let firstReaperPIDFile = root.appendingPathComponent("first-reaper.pid")
        let firstPublisherReady = root.appendingPathComponent("first-publisher-ready")
        let firstReaperRan = root.appendingPathComponent("first-reaper-ran")
        let replacementReady = root.appendingPathComponent("replacement-ready")
        let replacementRelease = root.appendingPathComponent("replacement-release")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "anchor|group|started\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        let policyFunctions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()
        let firstLauncher = """
        \(policyFunctions)
        cmux_ssh_auth_stable_identity() {
          cmux_test_stable_identity=$(/usr/bin/env LC_ALL=C LANG=C \\
            /bin/ps -o pgid= -o state= -o lstart= -p "$1" 2>/dev/null | \\
            /usr/bin/awk 'NF >= 7 && $2 !~ /Z/ {
              cmux_started = $3 "_" $4 "_" $5 "_" $6 "_" $7
              print $1 "|" cmux_started
            }')
          if [ "$1" != "$$" ] && \\
            /bin/mkdir "$CMUX_TEST_FIRST_IDENTITY_GATE" 2>/dev/null; then
            printf '%s\n' "$1" > "$CMUX_TEST_FIRST_REAPER_PID" || exit 99
            /bin/sh -c 'printf "%s\\n" "$PPID" > "$1"' \
              cmux-test-owner "$CMUX_TEST_FIRST_IDENTITY_CALLER_PID" || exit 98
            : > "$CMUX_TEST_FIRST_PUBLISHER_READY"
            while :; do /bin/sleep 1; done
          fi
          printf '%s\n' "$cmux_test_stable_identity"
        }
        cmux_ssh_terminate_owned_auth_group() {
          : > "$CMUX_TEST_FIRST_REAPER_RAN"
          return 1
        }
        cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
        wait "$!"
        """
        try firstLauncher.write(to: firstLauncherScript, atomically: true, encoding: .utf8)
        defer {
            for pidFile in [firstReaperPIDFile, firstIdentityCallerPIDFile] {
                if let processID = try? Int32(
                    String(contentsOf: pidFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ) {
                    Darwin.kill(processID, SIGKILL)
                }
            }
            try? fileManager.removeItem(at: root)
        }

        let command = """
        \(policyFunctions)
        "$CMUX_TEST_SHELL" "$CMUX_TEST_FIRST_LAUNCHER" &
        cmux_test_first_launcher=$!
        cmux_test_ready_attempt=0
        while [ ! -s "$CMUX_TEST_FIRST_REAPER_PID" ] && \\
          [ "$cmux_test_ready_attempt" -lt 500 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -s "$CMUX_TEST_FIRST_REAPER_PID" || exit 99
        /bin/kill -KILL "$cmux_test_first_launcher" 2>/dev/null || exit 98
        wait "$cmux_test_first_launcher" 2>/dev/null || true
        cmux_ssh_auth_reclaim_stale_reaper_lock \\
          "$CMUX_SSH_AUTH_GROUP_DIR/reaper.lock" || exit 97
        cmux_ssh_terminate_owned_auth_group() {
          : > "$CMUX_TEST_REPLACEMENT_READY"
          cmux_test_release_attempt=0
          while [ ! -e "$CMUX_TEST_REPLACEMENT_RELEASE" ] && \\
            [ "$cmux_test_release_attempt" -lt 500 ]; do
            /bin/sleep 0.01
            cmux_test_release_attempt=$((cmux_test_release_attempt + 1))
          done
          test -e "$CMUX_TEST_REPLACEMENT_RELEASE" || return 1
          /bin/rm -f -- "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        }
        cmux_ssh_launch_owned_auth_group_reaper "$CMUX_SSH_AUTH_GROUP_DIR"
        test "${CMUX_SSH_AUTH_REAPER_LAUNCHED:-0}" = 1 || exit 96
        cmux_test_replacement_reaper=$!
        cmux_test_replacement_attempt=0
        while [ ! -e "$CMUX_TEST_REPLACEMENT_READY" ] && \\
          [ "$cmux_test_replacement_attempt" -lt 500 ]; do
          /bin/sleep 0.01
          cmux_test_replacement_attempt=$((cmux_test_replacement_attempt + 1))
        done
        test -e "$CMUX_TEST_REPLACEMENT_READY" || exit 95
        cmux_test_orphan_attempt=0
        while [ ! -e "$CMUX_TEST_FIRST_REAPER_RAN" ] && \\
          [ "$cmux_test_orphan_attempt" -lt 100 ]; do
          /bin/sleep 0.01
          cmux_test_orphan_attempt=$((cmux_test_orphan_attempt + 1))
        done
        : > "$CMUX_TEST_REPLACEMENT_RELEASE"
        wait "$cmux_test_replacement_reaper" || exit 94
        test ! -e "$CMUX_TEST_FIRST_REAPER_RAN" || exit 93
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_FIRST_IDENTITY_GATE": root.appendingPathComponent("identity-gate").path,
                "CMUX_TEST_FIRST_IDENTITY_CALLER_PID": firstIdentityCallerPIDFile.path,
                "CMUX_TEST_FIRST_LAUNCHER": firstLauncherScript.path,
                "CMUX_TEST_FIRST_PUBLISHER_READY": firstPublisherReady.path,
                "CMUX_TEST_FIRST_REAPER_PID": firstReaperPIDFile.path,
                "CMUX_TEST_FIRST_REAPER_RAN": firstReaperRan.path,
                "CMUX_TEST_REPLACEMENT_READY": replacementReady.path,
                "CMUX_TEST_REPLACEMENT_RELEASE": replacementRelease.path,
                "CMUX_TEST_SHELL": shellPath,
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
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.0" || exit 96
        cmux_test_created=$(/bin/cat "$cmux_test_group/created") || exit 95
        case "$cmux_test_created" in ''|*[!0-9]*) exit 94 ;; esac
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func authenticationGroupFactoryRetriesTransientRecoveryLockFailure(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-factory-lock-retry-\(UUID().uuidString)", isDirectory: true)
        let lockAttempts = root.appendingPathComponent("lock-attempts")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_test_lock_attempts=0
        cmux_ssh_auth_recovery_lock() {
          cmux_test_lock_attempts=$((cmux_test_lock_attempts + 1))
          printf '%s\n' "$cmux_test_lock_attempts" > "$CMUX_TEST_LOCK_ATTEMPTS"
          [ "$cmux_test_lock_attempts" -ge 3 ]
        }
        cmux_ssh_auth_recovery_unlock() { :; }
        cmux_test_group=$(cmux_ssh_auth_create_group_dir) || exit 99
        test "$(/bin/cat "$CMUX_TEST_LOCK_ATTEMPTS")" -eq 3 || exit 98
        test -d "$cmux_test_group" || exit 97
        /usr/bin/grep -Fxq "$cmux_test_group" \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.0" || exit 96
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_LOCK_ATTEMPTS": lockAttempts.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

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
        /bin/cat "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.0" \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.1" \
          > "$CMUX_TEST_ENTRIES" || exit 98
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

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoveryQueueDeduplicatesAndCapsPendingGroups(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-bounded-queue-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_test_group="$TMPDIR/cmux-ssh-auth-group.duplicate"
        cmux_ssh_auth_recovery_enqueue "$cmux_test_group" || exit 99
        cmux_ssh_auth_recovery_enqueue "$cmux_test_group" || exit 98
        cmux_test_index=1
        while [ "$cmux_test_index" -lt 64 ]; do
          cmux_ssh_auth_recovery_enqueue \
            "$TMPDIR/cmux-ssh-auth-group.unique-$cmux_test_index" || exit 97
          cmux_test_index=$((cmux_test_index + 1))
        done
        if cmux_ssh_auth_recovery_enqueue \
          "$TMPDIR/cmux-ssh-auth-group.overflow"; then
          exit 96
        else
          cmux_test_overflow_status=$?
        fi
        test "$cmux_test_overflow_status" -eq 75 || exit 91
        /bin/cat \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)"/queue.[0-9]* \
          > "$CMUX_TEST_ENTRIES" || exit 95
        test "$(/usr/bin/wc -l < "$CMUX_TEST_ENTRIES" | /usr/bin/tr -d '[:space:]')" \
          -eq 64 || exit 94
        test "$(/usr/bin/sort -u "$CMUX_TEST_ENTRIES" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
          -eq 64 || exit 93
        test "$(/usr/bin/grep -Fxc "$cmux_test_group" "$CMUX_TEST_ENTRIES")" \
          -eq 1 || exit 92
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_ENTRIES": root.appendingPathComponent("entries").path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoveryCompletionFreesClaimedSegmentBeforeRetryAppend() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-completion-capacity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_recovery_prepare || exit 99
        recovery_root="$CMUX_SSH_AUTH_RECOVERY_ROOT"
        printf '0\\n' > "$recovery_root/read.index"
        printf '7\\n' > "$recovery_root/write.index"
        index=0
        while [ "$index" -le 7 ]; do
          : > "$recovery_root/queue.$index"
          line=0
          while [ "$line" -lt 8 ]; do
            printf '%s\\n' "$TMPDIR/cmux-ssh-auth-group.full-$index-$line" >> "$recovery_root/queue.$index"
            line=$((line + 1))
          done
          index=$((index + 1))
        done
        retry_group="$TMPDIR/cmux-ssh-auth-group.retry"
        (umask 077; mkdir "$retry_group") || exit 98
        printf 'owner\\n' > "$recovery_root/queue.0.claim"
        printf '%s\\n' "$retry_group" > "$recovery_root/queue.0.retry"
        CMUX_SSH_AUTH_RECOVERY_SEGMENT="$recovery_root/queue.0"
        CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX=0
        CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD=owner
        export CMUX_SSH_AUTH_RECOVERY_SEGMENT CMUX_SSH_AUTH_RECOVERY_SEGMENT_INDEX CMUX_SSH_AUTH_RECOVERY_CLAIM_RECORD
        cmux_ssh_auth_recovery_complete_segment || exit 97
        test "$(cat "$recovery_root/read.index")" = 1 || exit 96
        test -s "$recovery_root/queue.8" || exit 95
        grep -Fqx -- "$retry_group" "$recovery_root/queue.8" || exit 94
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func exitedCleanupOwnerIsAbandonedAfterIdentityReadFailure() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-cleanup-owner-exited-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(
            at: groupDirectory.appendingPathComponent("cleanup.lock"),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        : > "$CMUX_TEST_GROUP/cancel"
        printf '99999999|1|K_1_1\\n' > "$CMUX_TEST_GROUP/cleanup.owner"
        cmux_ssh_auth_stable_identity() { return 1; }
        cmux_ssh_auth_group_cleanup_is_abandoned "$CMUX_TEST_GROUP"
        """
        let result = try runShellCommand(command, environment: ["CMUX_TEST_GROUP": groupDirectory.path])

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
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/lock" \
          /usr/bin/true; then
          cmux_ssh_auth_recovery_unlock
          exit 98
        fi
        cmux_ssh_auth_recovery_unlock
        /usr/bin/lockf -s -t 1 \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/lock" \
          /usr/bin/true || exit 97
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoveryLockAvoidsNewerLockfDescriptorSyntax() {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()

        #expect(functions.contains("/usr/bin/perl -MFcntl=:flock"))
        #expect(!functions.contains("/usr/bin/lockf -s -t 1 9"))
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func sharedTmpRecoveryFallbackIsScopedToCurrentUser(shellPath: String) throws {
        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        unset TMPDIR
        cmux_ssh_auth_recovery_configure_paths || exit 99
        test "$cmux_ssh_auth_recovery_base" = /tmp || exit 98
        cmux_test_user_id=$(/usr/bin/id -u) || exit 97
        test "$cmux_ssh_auth_recovery_root" = \
          "/tmp/cmux-ssh-auth-recovery.$cmux_test_user_id" || exit 96
        """

        let result = try runShellCommand(command, shellPath: shellPath)

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func configuredTmpRecoveryRootIsScopedToCurrentUser(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-shared-tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_recovery_configure_paths || exit 99
        cmux_test_user_id=$(/usr/bin/id -u) || exit 98
        test "$cmux_ssh_auth_recovery_root" = \
          "$TMPDIR/cmux-ssh-auth-recovery.$cmux_test_user_id" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: ["TMPDIR": root.path],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func completedAuthenticationCleanupSchedulesLongLivedRecoveryQueueDrain() throws {
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
        cmux_test_drain_deadline=$(($(cmux_ssh_auth_now_millis) + 5000))
        while :; do
          cmux_test_queue_present=0
          for cmux_test_segment in \
            "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)"/queue.[0-9]*; do
            if [ -e "$cmux_test_segment" ]; then cmux_test_queue_present=1; fi
          done
          if [ "$cmux_test_queue_present" -eq 0 ]; then break; fi
          cmux_test_drain_now=$(cmux_ssh_auth_now_millis) || exit 97
          [ "$cmux_test_drain_now" -lt "$cmux_test_drain_deadline" ] || exit 96
          /bin/sleep 0.01
        done
        """

        let result = try runShellCommand(command, environment: ["TMPDIR": root.path])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func failedAuthenticationCleanupReenqueuesDurableRecoveryWork(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-cleanup-reenqueue-\(UUID().uuidString)",
                isDirectory: true
            )
        let groupDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.failed", isDirectory: true)
        let scheduledFile = root.appendingPathComponent("scheduled")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "anchor|group|started\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let cleanupBody = policy.authenticationGroupDirectoryCleanupShellBody(
            terminatesPublishedGroup: true
        )
        let command = """
        \(policy.processTreeTerminationShellFunction())
        cmux_ssh_terminate_owned_auth_group() { :; }
        cmux_ssh_launch_owned_auth_group_reaper() { :; }
        cmux_ssh_schedule_failed_auth_group_recovery() {
          cmux_ssh_auth_recovery_lock || return 1
          cmux_test_schedule_status=1
          if cmux_ssh_auth_recovery_queue_has_work_locked; then
            : > "$CMUX_TEST_SCHEDULED"
            cmux_test_schedule_status=0
          fi
          cmux_ssh_auth_recovery_unlock
          return "$cmux_test_schedule_status"
        }
        cmux_test_cleanup_auth_group() { \(cleanupBody) }
        cmux_test_cleanup_auth_group
        test -s "$CMUX_TEST_GROUP/identity" || exit 99
        test -e "$CMUX_TEST_SCHEDULED" || exit 98
        /usr/bin/grep -Fxq "$CMUX_TEST_GROUP" \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)"/queue.[0-9]* || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_GROUP": groupDirectory.path,
                "CMUX_TEST_SCHEDULED": scheduledFile.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

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
        cmux_test_anchor_identity=$(cmux_ssh_auth_identity "$$") || exit 95
        cmux_test_anchor_remainder=${cmux_test_anchor_identity#*|}
        printf '%s|%s\n' "$$" "$cmux_test_anchor_remainder" \
          > "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 95
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

    @Test func recoverySweepHoldsPublishedOrphanAndSkipsLivePublisher() throws {
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
        test ! -s "$CMUX_TEST_RECOVERY_CALLS" || exit 95
        test -s "$CMUX_TEST_ORPHAN_GROUP/identity" || exit 94
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

    @Test func publisherLivenessRequiresDurablePublisherRecord() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-publisher-record-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap 'exit 0' TERM; while :; do /bin/sleep 1; done ) &
        cmux_test_anchor=$!
        trap '/bin/kill -KILL "$cmux_test_anchor" >/dev/null 2>&1 || true' EXIT
        cmux_test_anchor_identity=$(cmux_ssh_auth_identity "$cmux_test_anchor") || exit 99
        cmux_test_anchor_remainder=${cmux_test_anchor_identity#*|}
        printf '%s|%s\n' "$cmux_test_anchor" "$cmux_test_anchor_remainder" \
          > "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 98
        if cmux_ssh_auth_group_publisher_is_live "$CMUX_SSH_AUTH_GROUP_DIR"; then exit 97; fi
        /bin/kill -TERM "$cmux_test_anchor" >/dev/null 2>&1 || true
        wait "$cmux_test_anchor" 2>/dev/null || true
        trap - EXIT
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySweepReapsStoppedPublisherWithAbandonedOrMissingCleanupOwner(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-stopped-publisher-\(UUID().uuidString)", isDirectory: true)
        let suspendedDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.suspended", isDirectory: true)
        let abandonedDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.abandoned", isDirectory: true)
        let activeDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.active", isDirectory: true)
        let ownerlessDirectory = root
            .appendingPathComponent("cmux-ssh-auth-group.ownerless", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: suspendedDirectory)
        try createSecureGroupDirectory(at: abandonedDirectory)
        try createSecureGroupDirectory(at: activeDirectory)
        try createSecureGroupDirectory(at: ownerlessDirectory)
        for directory in [
            suspendedDirectory,
            abandonedDirectory,
            activeDirectory,
            ownerlessDirectory,
        ] {
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
        /bin/sleep 30 &
        cmux_test_ownerless_publisher=$!
        trap '/bin/kill -KILL "$cmux_test_suspended_publisher" "$cmux_test_abandoned_publisher" "$cmux_test_active_publisher" "$cmux_test_ownerless_publisher" >/dev/null 2>&1 || true; wait "$cmux_test_suspended_publisher" "$cmux_test_abandoned_publisher" "$cmux_test_active_publisher" "$cmux_test_ownerless_publisher" 2>/dev/null || true' EXIT
        cmux_test_suspended_identity=$(cmux_ssh_auth_identity "$cmux_test_suspended_publisher") || exit 100
        cmux_test_abandoned_identity=$(cmux_ssh_auth_identity "$cmux_test_abandoned_publisher") || exit 99
        cmux_test_active_identity=$(cmux_ssh_auth_identity "$cmux_test_active_publisher") || exit 98
        cmux_test_ownerless_identity=$(cmux_ssh_auth_identity "$cmux_test_ownerless_publisher") || exit 97
        cmux_test_write_group_identity() {
          cmux_test_identity_group_dir=$1
          cmux_test_identity_pid=$2
          cmux_test_identity_record=$3
          cmux_test_identity_remainder=${cmux_test_identity_record#*|}
          printf '%s|%s\n' "$cmux_test_identity_pid" \
            "$cmux_test_identity_remainder" \
            > "$cmux_test_identity_group_dir/identity"
        }
        cmux_test_write_group_identity "$CMUX_TEST_SUSPENDED_GROUP" \
          "$cmux_test_suspended_publisher" "$cmux_test_suspended_identity" || exit 97
        cmux_test_write_group_identity "$CMUX_TEST_ABANDONED_GROUP" \
          "$cmux_test_abandoned_publisher" "$cmux_test_abandoned_identity" || exit 97
        cmux_test_write_group_identity "$CMUX_TEST_ACTIVE_GROUP" \
          "$cmux_test_active_publisher" "$cmux_test_active_identity" || exit 97
        cmux_test_write_group_identity "$CMUX_TEST_OWNERLESS_GROUP" \
          "$cmux_test_ownerless_publisher" "$cmux_test_ownerless_identity" || exit 97
        printf '%s|%s\n' "$cmux_test_suspended_publisher" "$cmux_test_suspended_identity" \
          > "$CMUX_TEST_SUSPENDED_GROUP/publisher" || exit 97
        printf '%s|%s\n' "$cmux_test_abandoned_publisher" "$cmux_test_abandoned_identity" \
          > "$CMUX_TEST_ABANDONED_GROUP/publisher" || exit 96
        printf '%s|%s\n' "$cmux_test_active_publisher" "$cmux_test_active_identity" \
          > "$CMUX_TEST_ACTIVE_GROUP/publisher" || exit 95
        printf '%s|%s\n' "$cmux_test_ownerless_publisher" "$cmux_test_ownerless_identity" \
          > "$CMUX_TEST_OWNERLESS_GROUP/publisher" || exit 94
        printf '999999|888888|777777|Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_TEST_ABANDONED_GROUP/cleanup.owner" || exit 94
        : > "$CMUX_TEST_ABANDONED_GROUP/cancel" || exit 93
        cmux_test_cleanup_owner_identity=$(cmux_ssh_auth_identity "$$") || exit 95
        printf '%s|%s\n' "$$" "$cmux_test_cleanup_owner_identity" \
          > "$CMUX_TEST_ACTIVE_GROUP/cleanup.owner" || exit 92
        : > "$CMUX_TEST_ACTIVE_GROUP/cancel" || exit 91
        : > "$CMUX_TEST_OWNERLESS_GROUP/cancel" || exit 90
        /bin/kill -STOP "$cmux_test_suspended_publisher" \
          "$cmux_test_abandoned_publisher" "$cmux_test_active_publisher" \
          "$cmux_test_ownerless_publisher" || exit 89
        cmux_test_stop_attempt=0
        while [ "$cmux_test_stop_attempt" -lt 100 ]; do
          if [ "$(cmux_ssh_auth_stopped_identity "$cmux_test_suspended_publisher")" = \
            "$cmux_test_suspended_identity" ] && \
            [ "$(cmux_ssh_auth_stopped_identity "$cmux_test_abandoned_publisher")" = \
            "$cmux_test_abandoned_identity" ] && \
            [ "$(cmux_ssh_auth_stopped_identity "$cmux_test_active_publisher")" = \
            "$cmux_test_active_identity" ] && \
            [ "$(cmux_ssh_auth_stopped_identity "$cmux_test_ownerless_publisher")" = \
            "$cmux_test_ownerless_identity" ]; then break; fi
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
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_OWNERLESS_GROUP" || exit 85
        cmux_ssh_resume_failed_auth_group_reapers || exit 84
        /usr/bin/grep -Fqx 'cmux-ssh-auth-group.abandoned' \
          "$CMUX_TEST_RECOVERY_CALLS" || exit 83
        /usr/bin/grep -Fqx 'cmux-ssh-auth-group.ownerless' \
          "$CMUX_TEST_RECOVERY_CALLS" || exit 82
        test "$(/usr/bin/wc -l < "$CMUX_TEST_RECOVERY_CALLS" | \
          /usr/bin/tr -d '[:space:]')" -eq 2 || exit 81
        test -s "$CMUX_TEST_SUSPENDED_GROUP/identity" || exit 83
        test -s "$CMUX_TEST_ACTIVE_GROUP/identity" || exit 82
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_ABANDONED_GROUP": abandonedDirectory.path,
                "CMUX_TEST_ACTIVE_GROUP": activeDirectory.path,
                "CMUX_TEST_OWNERLESS_GROUP": ownerlessDirectory.path,
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
        cmux_test_anchor_identity=$(cmux_ssh_auth_identity "$$") || exit 100
        cmux_test_anchor_remainder=${cmux_test_anchor_identity#*|}
        for cmux_test_group_dir in "$TMPDIR"/cmux-ssh-auth-group.*; do
          printf '%s|%s\n' "$$" "$cmux_test_anchor_remainder" \
            > "$cmux_test_group_dir/identity" || exit 100
        done
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
    func workerPublicationUsesFinalOwnerPaths(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-owner-paths-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.test",
            isDirectory: true
        )
        let calls = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_publish_current_worker() {
          printf 'worker-record\n' > "$1" || return 1
          printf '%s\n' "$1" >> "$CMUX_TEST_CALLS"
        }
        cmux_ssh_auth_cleanup_owner_file="$CMUX_TEST_GROUP/cleanup.owner"
        cmux_ssh_auth_cleanup_owner_publish_file="$CMUX_TEST_GROUP/cleanup.owner.new"
        cmux_ssh_auth_cleanup_lock="$CMUX_TEST_GROUP/cleanup.lock"
        cmux_ssh_auth_cleanup_lock_owner_file="$cmux_ssh_auth_cleanup_lock/owner"
        cmux_ssh_auth_cleanup_lock_owner_publish_file="$cmux_ssh_auth_cleanup_lock/owner.new"
        cmux_ssh_auth_cleanup_claim || exit 99
        cmux_ssh_auth_cleanup_claim_release
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_GROUP" || exit 98
        cmux_ssh_auth_recovery_claim_segment || exit 97
        /usr/bin/grep -Fqx "$CMUX_TEST_GROUP/cleanup.owner" "$CMUX_TEST_CALLS" || exit 96
        /usr/bin/grep -Fqx \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.0.claim" \
          "$CMUX_TEST_CALLS" || exit 95
        test "$(/usr/bin/awk 'END { print NR + 0 }' "$CMUX_TEST_CALLS")" -eq 2 || exit 94
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CALLS": calls.path,
                "CMUX_TEST_GROUP": groupDirectory.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

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
          /bin/chmod 500 \
            "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)" || exit 99
          return 1
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$TMPDIR/cmux-ssh-auth-group.test" || exit 98
        cmux_ssh_resume_failed_auth_group_reapers || exit 97
        /bin/chmod 700 \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)" || exit 96
        test -s \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/queue.0.claim" || exit 95
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

    @Test func recoverySweepRetainsExpiredDeadAnchorWithLiveOwnedProcess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-expired-owned-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.expired-owned",
            isDirectory: true
        )
        let snapshotCalled = root.appendingPathComponent("snapshot-called")
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
        try "101 1 777 Thu_Jan_1_00:00:00_1970 S\n".write(
            to: groupDirectory.appendingPathComponent("owned"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_take_process_snapshot_until() {
          : > "$CMUX_TEST_SNAPSHOT_CALLED"
          printf '101 1 777 S Thu_Jan_1_00:00:00_1970\n' > "$1"
        }
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_GROUP_DIR" || exit 99
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        test -e "$CMUX_TEST_SNAPSHOT_CALLED" || exit 97
        test -d "$CMUX_TEST_GROUP_DIR" || exit 96
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970 S' \
          "$CMUX_TEST_GROUP_DIR/owned" || exit 95
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_TEST_GROUP_DIR": groupDirectory.path,
            "CMUX_TEST_SNAPSHOT_CALLED": snapshotCalled.path,
            "TMPDIR": root.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func recoverySweepTerminatesExpiredDeadAnchorOwnedProcess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-expired-cleanup-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.expired-cleanup",
            isDirectory: true
        )
        let killed = root.appendingPathComponent("killed")
        let signals = root.appendingPathComponent("signals")
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
        try "101 1 777 Thu_Jan_1_00:00:00_1970 S\n".write(
            to: groupDirectory.appendingPathComponent("owned"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_take_process_snapshot_until() {
          test "$cmux_ssh_auth_caller_group" = 0 || return 1
          if [ -e "$CMUX_TEST_KILLED" ]; then
            : > "$1"
          else
            printf '101 1 777 T Thu_Jan_1_00:00:00_1970\n' > "$1"
          fi
        }
        cmux_ssh_auth_stable_identity() {
          case "$1" in
            101) printf '777|Thu_Jan_1_00:00:00_1970\n' ;;
            *) return 1 ;;
          esac
        }
        kill() {
          printf '%s\n' "$*" >> "$CMUX_TEST_SIGNALS"
          case "$*" in *-KILL*) : > "$CMUX_TEST_KILLED" ;; esac
        }
        : > "$CMUX_TEST_SIGNALS"
        CMUX_SSH_AUTH_GROUP_DIR=
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_auth_recovery_enqueue "$CMUX_TEST_GROUP_DIR" || exit 99
        cmux_ssh_resume_failed_auth_group_reapers || exit 98
        /usr/bin/grep -Fq -- '-KILL' "$CMUX_TEST_SIGNALS" || exit 97
        test ! -d "$CMUX_TEST_GROUP_DIR" || exit 96
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_TEST_GROUP_DIR": groupDirectory.path,
            "CMUX_TEST_KILLED": killed.path,
            "CMUX_TEST_SIGNALS": signals.path,
            "TMPDIR": root.path,
        ])

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
        cmux_test_anchor_identity=$(cmux_ssh_auth_identity "$$") || exit 100
        cmux_test_anchor_remainder=${cmux_test_anchor_identity#*|}
        for cmux_test_group_dir in "$TMPDIR"/cmux-ssh-auth-group.*; do
          printf '%s|%s\n' "$$" "$cmux_test_anchor_remainder" \
            > "$cmux_test_group_dir/identity" || exit 100
        done
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

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySweepSchedulingDoesNotBlockStartupOrHideCurrentQueueEntry(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-scheduling-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_resume_failed_auth_group_reapers() {
          if [ -n "${CMUX_SSH_AUTH_GROUP_DIR:-}" ]; then
            : > "$CMUX_TEST_RECOVERY_GROUP_LEAK"
          fi
          : > "$CMUX_TEST_RECOVERY_STARTED"
          cmux_test_worker_deadline=$(($(cmux_ssh_auth_now_millis) + 2000))
          while [ ! -e "$CMUX_TEST_RECOVERY_RELEASE" ]; do
            cmux_test_worker_now=$(cmux_ssh_auth_now_millis) || return 90
            [ "$cmux_test_worker_now" -lt "$cmux_test_worker_deadline" ] || return 90
            /bin/sleep 0.01
          done
          : > "$CMUX_TEST_RECOVERY_DONE"
        }
        CMUX_SSH_AUTH_GROUP_DIR="$TMPDIR/cmux-ssh-auth-group.current"
        export CMUX_SSH_AUTH_GROUP_DIR
        cmux_ssh_schedule_failed_auth_group_recovery || exit 99
        : > "$CMUX_TEST_STARTUP_CONTINUED"
        test -e "$CMUX_TEST_STARTUP_CONTINUED" || exit 98

        cmux_test_started_deadline=$(($(cmux_ssh_auth_now_millis) + 1000))
        while [ ! -e "$CMUX_TEST_RECOVERY_STARTED" ]; do
          cmux_test_started_now=$(cmux_ssh_auth_now_millis) || exit 97
          [ "$cmux_test_started_now" -lt "$cmux_test_started_deadline" ] || exit 96
          /bin/sleep 0.01
        done
        : > "$CMUX_TEST_RECOVERY_RELEASE"

        cmux_test_done_deadline=$(($(cmux_ssh_auth_now_millis) + 1000))
        while [ ! -e "$CMUX_TEST_RECOVERY_DONE" ]; do
          cmux_test_done_now=$(cmux_ssh_auth_now_millis) || exit 95
          [ "$cmux_test_done_now" -lt "$cmux_test_done_deadline" ] || exit 94
          /bin/sleep 0.01
        done
        [ ! -e "$CMUX_TEST_RECOVERY_GROUP_LEAK" ] || exit 93
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_RECOVERY_DONE": root.appendingPathComponent("done").path,
                "CMUX_TEST_RECOVERY_GROUP_LEAK": root.appendingPathComponent("group-leak").path,
                "CMUX_TEST_RECOVERY_RELEASE": root.appendingPathComponent("release").path,
                "CMUX_TEST_RECOVERY_STARTED": root.appendingPathComponent("started").path,
                "CMUX_TEST_STARTUP_CONTINUED": root.appendingPathComponent("continued").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func processSnapshotsEnumerateOnlyOwnedGroupsAndDescendants() {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()

        #expect(
            !functions.contains("syscall(\n              336, 1, 1, 0, 0"),
            "Authentication cleanup must not enumerate every PID on the machine"
        )
        #expect(
            functions.contains("my $PROC_PGRP_ONLY = 2;") &&
                functions.contains("my $PROC_PPID_ONLY = 6;"),
            "Authentication cleanup must enumerate only owned process groups and descendants"
        )
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySchedulerCoalescesBeforeForkingWorker(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-recovery-coalescing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_resume_failed_auth_group_reapers() {
          printf 'started\\n' >> "$CMUX_TEST_RECOVERY_STARTED"
          cmux_test_worker_deadline=$(($(cmux_ssh_auth_now_millis) + 3000))
          while [ ! -e "$CMUX_TEST_RECOVERY_RELEASE" ]; do
            cmux_test_worker_now=$(cmux_ssh_auth_now_millis) || return 90
            [ "$cmux_test_worker_now" -lt "$cmux_test_worker_deadline" ] || return 90
            /bin/sleep 0.01
          done
          printf 'done\\n' >> "$CMUX_TEST_RECOVERY_DONE"
        }
        cmux_ssh_schedule_failed_auth_group_recovery || exit 99
        cmux_ssh_schedule_failed_auth_group_recovery || exit 98

        cmux_test_started_deadline=$(($(cmux_ssh_auth_now_millis) + 1000))
        while :; do
          cmux_test_started_count=$(/usr/bin/awk 'END { print NR + 0 }' \
            "$CMUX_TEST_RECOVERY_STARTED" 2>/dev/null || printf '0\\n')
          [ "$cmux_test_started_count" -ge 1 ] && break
          cmux_test_started_now=$(cmux_ssh_auth_now_millis) || exit 97
          [ "$cmux_test_started_now" -lt "$cmux_test_started_deadline" ] || exit 96
          /bin/sleep 0.01
        done

        cmux_test_settle_deadline=$(($(cmux_ssh_auth_now_millis) + 500))
        while :; do
          cmux_test_settle_now=$(cmux_ssh_auth_now_millis) || exit 95
          [ "$cmux_test_settle_now" -lt "$cmux_test_settle_deadline" ] || break
          /bin/sleep 0.01
        done
        cmux_test_started_count=$(/usr/bin/awk 'END { print NR + 0 }' \
          "$CMUX_TEST_RECOVERY_STARTED" 2>/dev/null || printf '0\\n')
        : > "$CMUX_TEST_RECOVERY_RELEASE"

        cmux_test_done_deadline=$(($(cmux_ssh_auth_now_millis) + 1000))
        while :; do
          cmux_test_done_count=$(/usr/bin/awk 'END { print NR + 0 }' \
            "$CMUX_TEST_RECOVERY_DONE" 2>/dev/null || printf '0\\n')
          [ "$cmux_test_done_count" -ge "$cmux_test_started_count" ] && break
          cmux_test_done_now=$(cmux_ssh_auth_now_millis) || exit 94
          [ "$cmux_test_done_now" -lt "$cmux_test_done_deadline" ] || exit 93
          /bin/sleep 0.01
        done
        [ "$cmux_test_started_count" -eq 1 ] || exit 92
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_RECOVERY_DONE": root.appendingPathComponent("done").path,
                "CMUX_TEST_RECOVERY_RELEASE": root.appendingPathComponent("release").path,
                "CMUX_TEST_RECOVERY_STARTED": root.appendingPathComponent("started").path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySchedulerContinuesWhileQueueHasWork(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-recovery-drain-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_resume_failed_auth_group_reapers() {
          cmux_test_started_count=$(/usr/bin/awk 'END { print NR + 0 }' \
            "$CMUX_TEST_RECOVERY_STARTED" 2>/dev/null || printf '0\n')
          cmux_test_started_count=$((cmux_test_started_count + 1))
          printf '%s|%s\n' "$cmux_test_started_count" \
            "${CMUX_SSH_AUTH_RECOVERY_BACKOFF_SECONDS:-}" \
            >> "$CMUX_TEST_RECOVERY_STARTED"
          if [ "$cmux_test_started_count" -ge 3 ]; then
            /bin/rm -f -- "$CMUX_TEST_QUEUE_WORK"
          fi
        }
        cmux_ssh_auth_recovery_queue_has_work_locked() {
          [ -e "$CMUX_TEST_QUEUE_WORK" ]
        }
        : > "$CMUX_TEST_QUEUE_WORK"
        cmux_ssh_schedule_failed_auth_group_recovery || exit 99

        cmux_test_started_deadline=$(($(cmux_ssh_auth_now_millis) + 8000))
        while :; do
          cmux_test_started_count=$(/usr/bin/awk 'END { print NR + 0 }' \
            "$CMUX_TEST_RECOVERY_STARTED" 2>/dev/null || printf '0\n')
          [ "$cmux_test_started_count" -ge 3 ] && break
          cmux_test_started_now=$(cmux_ssh_auth_now_millis) || exit 98
          [ "$cmux_test_started_now" -lt "$cmux_test_started_deadline" ] || exit 97
          /bin/sleep 0.01
        done

        cmux_test_release_deadline=$(($(cmux_ssh_auth_now_millis) + 2000))
        while [ -d \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/sweep.lock" ]; do
          cmux_test_release_now=$(cmux_ssh_auth_now_millis) || exit 96
          [ "$cmux_test_release_now" -lt "$cmux_test_release_deadline" ] || exit 95
          /bin/sleep 0.01
        done
        [ "$cmux_test_started_count" -eq 3 ] || exit 94
        cmux_test_expected_backoff=$(/usr/bin/printf '1|1\n2|2\n3|4\n')
        [ "$(/bin/cat "$CMUX_TEST_RECOVERY_STARTED")" = \
          "$cmux_test_expected_backoff" ] || exit 93
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_QUEUE_WORK": root.appendingPathComponent("queue-work").path,
                "CMUX_TEST_RECOVERY_STARTED": root.appendingPathComponent("started").path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySchedulerRunsDelayedSweepAfterPassLimit(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-recovery-delayed-sweep-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_resume_failed_auth_group_reapers() {
          cmux_test_pass_count=$(/usr/bin/awk 'END { print NR + 0 }' \
            "$CMUX_TEST_PASSES" 2>/dev/null || printf '0\n')
          cmux_test_pass_count=$((cmux_test_pass_count + 1))
          printf '%s\n' "$cmux_test_pass_count" >> "$CMUX_TEST_PASSES"
          if [ "$cmux_test_pass_count" -ge 2 ]; then
            /bin/rm -f -- "$CMUX_TEST_QUEUE_WORK"
          fi
        }
        cmux_ssh_auth_recovery_queue_has_work_locked() {
          [ -e "$CMUX_TEST_QUEUE_WORK" ]
        }
        : > "$CMUX_TEST_QUEUE_WORK"
        CMUX_SSH_AUTH_RECOVERY_MAX_PASSES=1
        CMUX_SSH_AUTH_RECOVERY_RETENTION_RECHECK_SECONDS=1
        export CMUX_SSH_AUTH_RECOVERY_MAX_PASSES \
          CMUX_SSH_AUTH_RECOVERY_RETENTION_RECHECK_SECONDS
        cmux_ssh_schedule_failed_auth_group_recovery || exit 99

        cmux_test_delay_owner="$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/delay.lock/owner"
        cmux_test_owner_deadline=$(($(cmux_ssh_auth_now_millis) + 2000))
        while [ ! -s "$cmux_test_delay_owner" ]; do
          cmux_test_owner_now=$(cmux_ssh_auth_now_millis) || exit 98
          [ "$cmux_test_owner_now" -lt "$cmux_test_owner_deadline" ] || exit 97
          /bin/sleep 0.01
        done
        cmux_ssh_auth_recorded_process_is_live "$cmux_test_delay_owner" || exit 96

        cmux_test_done_deadline=$(($(cmux_ssh_auth_now_millis) + 5000))
        while [ "$(/usr/bin/awk 'END { print NR + 0 }' \
          "$CMUX_TEST_PASSES" 2>/dev/null || printf '0\n')" -lt 2 ]; do
          cmux_test_done_now=$(cmux_ssh_auth_now_millis) || exit 95
          [ "$cmux_test_done_now" -lt "$cmux_test_done_deadline" ] || exit 94
          /bin/sleep 0.01
        done
        while [ -d "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/sweep.lock" ] || \
          [ -d "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/delay.lock" ]; do
          cmux_test_done_now=$(cmux_ssh_auth_now_millis) || exit 93
          [ "$cmux_test_done_now" -lt "$cmux_test_done_deadline" ] || exit 92
          /bin/sleep 0.01
        done
        test ! -e "$CMUX_TEST_QUEUE_WORK" || exit 91
        test ! -e \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/sweep.failed" || exit 90
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_PASSES": root.appendingPathComponent("passes").path,
                "CMUX_TEST_QUEUE_WORK": root.appendingPathComponent("queue-work").path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySchedulerRetainsOwnerDuringBackoff(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-recovery-owner-backoff-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_resume_failed_auth_group_reapers() {
          cmux_test_pass_count=$(/usr/bin/awk 'END { print NR + 0 }' \
            "$CMUX_TEST_PASSES" 2>/dev/null || printf '0\n')
          cmux_test_pass_count=$((cmux_test_pass_count + 1))
          printf '%s\n' "$cmux_test_pass_count" >> "$CMUX_TEST_PASSES"
          if [ "$cmux_test_pass_count" -ge 2 ]; then
            /bin/rm -f -- "$CMUX_TEST_QUEUE_WORK"
          fi
        }
        cmux_ssh_auth_recovery_queue_has_work_locked() {
          [ -e "$CMUX_TEST_QUEUE_WORK" ]
        }
        : > "$CMUX_TEST_QUEUE_WORK"
        cmux_ssh_schedule_failed_auth_group_recovery || exit 99

        cmux_test_first_deadline=$(($(cmux_ssh_auth_now_millis) + 2000))
        while [ "$(/usr/bin/awk 'END { print NR + 0 }' \
          "$CMUX_TEST_PASSES" 2>/dev/null || printf '0\n')" -lt 1 ]; do
          cmux_test_first_now=$(cmux_ssh_auth_now_millis) || exit 98
          [ "$cmux_test_first_now" -lt "$cmux_test_first_deadline" ] || exit 97
          /bin/sleep 0.01
        done
        cmux_test_owner="$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/sweep.lock/owner"
        test -s "$cmux_test_owner" || exit 96
        cmux_test_first_owner=$(/bin/cat "$cmux_test_owner") || exit 95
        /bin/sleep 0.2
        test -s "$cmux_test_owner" || exit 94
        test "$(/bin/cat "$cmux_test_owner")" = "$cmux_test_first_owner" || exit 93
        cmux_ssh_schedule_failed_auth_group_recovery || exit 92

        cmux_test_done_deadline=$(($(cmux_ssh_auth_now_millis) + 4000))
        while [ "$(/usr/bin/awk 'END { print NR + 0 }' \
          "$CMUX_TEST_PASSES" 2>/dev/null || printf '0\n')" -lt 2 ]; do
          cmux_test_done_now=$(cmux_ssh_auth_now_millis) || exit 91
          [ "$cmux_test_done_now" -lt "$cmux_test_done_deadline" ] || exit 90
          /bin/sleep 0.01
        done
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_PASSES": root.appendingPathComponent("passes").path,
                "CMUX_TEST_QUEUE_WORK": root.appendingPathComponent("queue-work").path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func recoverySchedulerDetachesWorkerFileDescriptors(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-recovery-detached-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_resume_failed_auth_group_reapers() {
          : > "$CMUX_TEST_RECOVERY_STARTED"
        }
        cmux_ssh_auth_recovery_queue_has_work_locked() { return 1; }
        cmux_ssh_auth_reaper_generation_is_current() {
          if [ -e "$CMUX_TEST_RECOVERY_STARTED" ]; then
            printf 'cmux-recovery-worker-stderr-open\n' >&2
          fi
          return 0
        }
        cmux_ssh_schedule_failed_auth_group_recovery || exit 99

        cmux_test_started_deadline=$(($(cmux_ssh_auth_now_millis) + 2000))
        while [ ! -e "$CMUX_TEST_RECOVERY_STARTED" ]; do
          cmux_test_started_now=$(cmux_ssh_auth_now_millis) || exit 98
          [ "$cmux_test_started_now" -lt "$cmux_test_started_deadline" ] || exit 97
          /bin/sleep 0.01
        done
        cmux_test_release_deadline=$(($(cmux_ssh_auth_now_millis) + 2000))
        while [ -d \
          "$TMPDIR/cmux-ssh-auth-recovery.$(/usr/bin/id -u)/sweep.lock" ]; do
          cmux_test_release_now=$(cmux_ssh_auth_now_millis) || exit 96
          [ "$cmux_test_release_now" -lt "$cmux_test_release_deadline" ] || exit 95
          /bin/sleep 0.01
        done
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_RECOVERY_STARTED": root
                    .appendingPathComponent("started").path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        #expect(!result.standardError.contains("cmux-recovery-worker-stderr-open"))
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
        cmux_test_anchor_identity=$(cmux_ssh_auth_identity "$$") || exit 99
        cmux_test_anchor_remainder=${cmux_test_anchor_identity#*|}
        printf '%s|%s\n' "$$" "$cmux_test_anchor_remainder" \
          > "$TMPDIR/cmux-ssh-auth-group.test/identity" || exit 99
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

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func liveReaperLockOwnerSurvivesTransientIdentityReadFailure(
        shellPath: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-ssh-auth-live-unreadable-lock-\(UUID().uuidString)",
                isDirectory: true
            )
        let lockDirectory = root.appendingPathComponent("reaper.lock", isDirectory: true)
        try fileManager.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
        cmux_test_owner_pid=$!
        trap '/bin/kill -KILL "$cmux_test_owner_pid" >/dev/null 2>&1 || true' EXIT
        printf '%s|1|K_unreadable\n' "$cmux_test_owner_pid" \
          > "$CMUX_TEST_LOCK/owner" || exit 99
        cmux_ssh_auth_stable_identity() { return 1; }
        if cmux_ssh_auth_reclaim_stale_reaper_lock "$CMUX_TEST_LOCK"; then exit 98; fi
        test -d "$CMUX_TEST_LOCK" || exit 97
        test -s "$CMUX_TEST_LOCK/owner" || exit 96
        /bin/kill -KILL "$cmux_test_owner_pid" >/dev/null 2>&1 || exit 95
        wait "$cmux_test_owner_pid" 2>/dev/null || true
        trap - EXIT
        """

        let result = try runShellCommand(
            command,
            environment: ["CMUX_TEST_LOCK": lockDirectory.path],
            shellPath: shellPath
        )

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
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/cleanup.owner" || exit 95
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/cleanup.lock/owner" || exit 94
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

    @Test func killedPublisherCannotStrandUnpublishedAnchor() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-unpublished-anchor-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let pendingIdentity = groupDirectory.appendingPathComponent("identity.new")
        let groupRecord = root.appendingPathComponent("group-record")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        #expect(Darwin.mkfifo(pendingIdentity.path, 0o600) == 0)
        defer {
            if let groupID = processGroupID(in: groupRecord) {
                Darwin.kill(-groupID, SIGKILL)
            }
            try? fileManager.removeItem(at: root)
        }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: "while :; do /bin/sleep 30; done"
        )
        let command = """
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        cmux_test_publish_attempt=0
        while [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/publisher.new" ] && \\
          [ "$cmux_test_publish_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_publish_attempt=$((cmux_test_publish_attempt + 1))
        done
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/publisher.new" || exit 99
        test ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 98
        /bin/cp "$CMUX_SSH_AUTH_GROUP_DIR/publisher.new" \\
          "$CMUX_TEST_GROUP_RECORD" || exit 97
        cmux_test_publisher=$(/usr/bin/awk -F '|' '{ print $1 }' \\
          "$CMUX_TEST_GROUP_RECORD")
        cmux_test_group=$(/usr/bin/awk -F '|' '{ print $2 }' \\
          "$CMUX_TEST_GROUP_RECORD")
        test "$cmux_test_publisher" = "$cmux_test_group" || exit 96
        /bin/kill -KILL "$cmux_test_publisher" 2>/dev/null || exit 95
        cmux_test_group_attempt=0
        while /bin/kill -0 -- "-$cmux_test_group" 2>/dev/null && \\
          [ "$cmux_test_group_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_group_attempt=$((cmux_test_group_attempt + 1))
        done
        /bin/kill -KILL "$cmux_test_auth_root" 2>/dev/null || true
        wait "$cmux_test_auth_root" 2>/dev/null || true
        if /bin/kill -0 -- "-$cmux_test_group" 2>/dev/null; then exit 94; fi
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
            "CMUX_TEST_GROUP_RECORD": groupRecord.path,
        ])
        let groupID = try #require(processGroupID(in: groupRecord))

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        #expect(Darwin.kill(-groupID, 0) != 0)
    }

    @Test func authenticationCommandDoesNotInheritAnchorGuardDescriptor() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-anchor-descriptor-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let inheritedMarker = root.appendingPathComponent("inherited")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            if /usr/sbin/lsof -a -p "$$" -Fn 2>/dev/null | \
              /usr/bin/grep -Fq "$CMUX_TEST_ANCHOR_TOKEN"; then
              : > "$CMUX_TEST_INHERITED_MARKER"
            fi
            """
        )
        let result = try runShellCommand(classifiedAuthentication, environment: [
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
            "CMUX_TEST_ANCHOR_TOKEN": root.lastPathComponent,
            "CMUX_TEST_INHERITED_MARKER": inheritedMarker.path,
        ])

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        #expect(!fileManager.fileExists(atPath: inheritedMarker.path))
    }

    @Test func nestedAuthenticationCleanupRetainsLiveHandoffOwner() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-nested-handoff-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(in: ":")
        let command = """
        \(policy.processIdentityShellFunctions())
        ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
        cmux_test_handoff_owner=$!
        trap '/bin/kill -KILL "$cmux_test_handoff_owner" >/dev/null 2>&1 || true' EXIT
        cmux_test_handoff_identity=$(cmux_ssh_auth_identity "$cmux_test_handoff_owner") || exit 99
        printf '%s|%s\n' "$cmux_test_handoff_owner" "$cmux_test_handoff_identity" \
          > "$CMUX_SSH_AUTH_GROUP_DIR/handoff.owner" || exit 98
        printf 'preserved\n' > "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 97
        : > "$CMUX_SSH_AUTH_GROUP_DIR/cancel"
        \(classifiedAuthentication) >/dev/null 2>&1 || true
        /usr/bin/grep -Fqx 'preserved' "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 96
        test -f "$CMUX_SSH_AUTH_GROUP_DIR/cancel" || exit 95
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/handoff.owner" || exit 94
        /bin/kill -KILL "$cmux_test_handoff_owner" >/dev/null 2>&1 || true
        wait "$cmux_test_handoff_owner" 2>/dev/null || true
        trap - EXIT
        """

        let result = try runShellCommand(
            command,
            environment: ["CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path]
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test func killedPublisherCannotStrandPublishedAnchor() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-published-anchor-\(UUID().uuidString)", isDirectory: true)
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let groupRecord = root.appendingPathComponent("group-record")
        let readyMarker = root.appendingPathComponent("ready")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer {
            if let groupID = processGroupID(in: groupRecord) {
                Darwin.kill(-groupID, SIGKILL)
            }
            try? fileManager.removeItem(at: root)
        }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: ": > \"$CMUX_TEST_READY_MARKER\"; while :; do /bin/sleep 30; done"
        )
        let command = """
        ( \(classifiedAuthentication) ) &
        cmux_test_auth_root=$!
        cmux_test_publish_attempt=0
        while { [ ! -f "$CMUX_TEST_READY_MARKER" ] || \
          [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" ] || \
          [ ! -s "$CMUX_SSH_AUTH_GROUP_DIR/publisher" ]; } && \
          [ "$cmux_test_publish_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_publish_attempt=$((cmux_test_publish_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 99
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 98
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/publisher" || exit 97
        /bin/cp "$CMUX_SSH_AUTH_GROUP_DIR/identity" "$CMUX_TEST_GROUP_RECORD" || exit 96
        cmux_test_publisher=$(/usr/bin/awk -F '|' '{ print $1 }' \
          "$CMUX_SSH_AUTH_GROUP_DIR/publisher")
        cmux_test_group=$(/usr/bin/awk -F '|' '{ print $2 }' \
          "$CMUX_TEST_GROUP_RECORD")
        /bin/kill -KILL "$cmux_test_publisher" 2>/dev/null || exit 95
        cmux_test_group_attempt=0
        while /bin/kill -0 -- "-$cmux_test_group" 2>/dev/null && \
          [ "$cmux_test_group_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_group_attempt=$((cmux_test_group_attempt + 1))
        done
        /bin/kill -KILL "$cmux_test_auth_root" 2>/dev/null || true
        wait "$cmux_test_auth_root" 2>/dev/null || true
        if /bin/kill -0 -- "-$cmux_test_group" 2>/dev/null; then exit 94; fi
        """

        let result = try runShellCommand(command, environment: [
            "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
            "CMUX_TEST_GROUP_RECORD": groupRecord.path,
            "CMUX_TEST_READY_MARKER": readyMarker.path,
        ])
        let groupID = try #require(processGroupID(in: groupRecord))

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        #expect(Darwin.kill(-groupID, 0) != 0)
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func authenticationGroupCleanupRetainsUnresolvedCancellation(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-cancel-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try "pending\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let cleanupBody = SSHForegroundAuthenticationRetryPolicy()
            .authenticationGroupDirectoryCleanupShellBody(terminatesPublishedGroup: true)
        let command = """
        cmux_test_group_dir="$CMUX_SSH_AUTH_GROUP_DIR"
        cmux_ssh_terminate_owned_auth_group() {
          : > "$CMUX_SSH_AUTH_GROUP_DIR/cancel"
          : > "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        }
        cmux_ssh_resume_failed_auth_group_reapers() { :; }
        \(cleanupBody)
        test -d "$cmux_test_group_dir" || exit 99
        test -e "$cmux_test_group_dir/cancel" || exit 98
        """

        let result = try runShellCommand(
            command,
            environment: ["CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func replacementCleanupRecoversStopJournalBeforeTruncating(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-stop-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        let recoveredMarker = root.appendingPathComponent("recovered")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let started = "Thu_Jan_1_00:00:00_1970"
        try "101|888|\(started)\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        try "101 1 888 \(started) T\n".write(
            to: groupDirectory.appendingPathComponent("frozen"),
            atomically: true,
            encoding: .utf8
        )
        try "888\n".write(
            to: groupDirectory.appendingPathComponent("signaled.groups"),
            atomically: true,
            encoding: .utf8
        )
        try "101 1 888 \(started)\n".write(
            to: groupDirectory.appendingPathComponent("signaled.pids"),
            atomically: true,
            encoding: .utf8
        )

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_identity() { printf '1|888|Thu_Jan_1_00:00:00_1970\n'; }
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_run_cleanup_transactions() { return 0; }
        cmux_ssh_auth_resume_signaled_processes() {
          /usr/bin/grep -Fqx '101 1 888 Thu_Jan_1_00:00:00_1970 T' \
            "$cmux_ssh_auth_frozen_processes" || return 1
          /usr/bin/grep -Fqx '888' "$cmux_ssh_auth_signaled_groups" || return 1
          /usr/bin/grep -Fqx '101 1 888 Thu_Jan_1_00:00:00_1970' \
            "$cmux_ssh_auth_signaled_processes" || return 1
          : > "$CMUX_TEST_RECOVERED"
        }
        cmux_ssh_terminate_owned_auth_group 999
        test -e "$CMUX_TEST_RECOVERED" || exit 99
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_RECOVERED": recoveredMarker.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func replacementCleanupPreservesStopJournalWhenRecoveryFails(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-stop-journal-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let started = "Thu_Jan_1_00:00:00_1970"
        try "101|888|\(started)\n".write(
            to: groupDirectory.appendingPathComponent("identity"),
            atomically: true,
            encoding: .utf8
        )
        try "101 1 888 \(started) T\n".write(
            to: groupDirectory.appendingPathComponent("frozen"),
            atomically: true,
            encoding: .utf8
        )
        try "101 1 888 \(started)\n".write(
            to: groupDirectory.appendingPathComponent("signaled.pids"),
            atomically: true,
            encoding: .utf8
        )

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_identity() { printf '1|888|Thu_Jan_1_00:00:00_1970\n'; }
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_run_cleanup_transactions() { return 0; }
        cmux_ssh_auth_resume_signaled_processes() { return 1; }
        cmux_ssh_terminate_owned_auth_group 999
        /usr/bin/grep -Fqx '101 1 888 Thu_Jan_1_00:00:00_1970 T' \
          "$CMUX_SSH_AUTH_GROUP_DIR/frozen" || exit 99
        /usr/bin/grep -Fqx '101 1 888 Thu_Jan_1_00:00:00_1970' \
          "$CMUX_SSH_AUTH_GROUP_DIR/signaled.pids" || exit 98
        """

        let result = try runShellCommand(
            command,
            environment: ["CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
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

    @Test func unpublishedFallbackFreezesRootBeforeDescendantDiscovery() throws {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()
        let fallbackStart = try #require(
            functions.range(of: "cmux_ssh_auth_force_unpublished_process_tree() (")
        )
        let durableStart = try #require(
            functions.range(
                of: "cmux_ssh_terminate_unpublished_auth_process_tree() (",
                range: fallbackStart.upperBound..<functions.endIndex
            )
        )
        let fallback = functions[fallbackStart.lowerBound..<durableStart.lowerBound]
        let writeAheadRecord = try #require(
            fallback.range(of: "cmux_ssh_auth_direct_stopped_records=")
        )
        let rootStop = try #require(
            fallback.range(of: "kill -STOP \"$cmux_ssh_auth_direct_freeze_pid\"")
        )
        let descendantDiscovery = try #require(
            fallback.range(of: "/usr/bin/pgrep -P")
        )

        #expect(writeAheadRecord.lowerBound < rootStop.lowerBound)
        #expect(rootStop.lowerBound < descendantDiscovery.lowerBound)
        #expect(fallback.contains("cmux_ssh_auth_stopped_identity"))
        #expect(fallback.contains("kill -CONT"))
        #expect(fallback.contains("printf '%s\\n%s|%s|%s'"))
    }

    @Test func unpublishedFallbackDoesNotKillAfterIncompleteDiscovery() throws {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()
        let fallbackStart = try #require(
            functions.range(of: "cmux_ssh_auth_force_unpublished_process_tree() (")
        )
        let durableStart = try #require(
            functions.range(
                of: "cmux_ssh_terminate_unpublished_auth_process_tree() (",
                range: fallbackStart.upperBound..<functions.endIndex
            )
        )
        let fallback = functions[fallbackStart.lowerBound..<durableStart.lowerBound]
        let incompleteDiscoveryExit = try #require(
            fallback.range(
                of: "if [ \"$cmux_ssh_auth_direct_capture_status\" != 0 ]; then exit"
            )
        )
        let firstKill = try #require(
            fallback.range(of: "kill -KILL \"$cmux_ssh_auth_direct_pid\"")
        )

        #expect(incompleteDiscoveryExit.lowerBound < firstKill.lowerBound)
        #expect(fallback.contains("trap 'cmux_ssh_auth_direct_resume_stopped' EXIT"))
    }

    @Test func cleanupClaimsOwnershipBeforeCancellationAndFreezeTransaction() throws {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()
        let claimAcquisition = try #require(
            functions.range(of: "cmux_ssh_auth_cleanup_claim || exit 0")
        )
        let cancellationPublication = try #require(
            functions.range(of: ": > \"$cmux_ssh_auth_group_cancel_file\" 2>/dev/null || exit 0")
        )
        let cleanupTransaction = try #require(
            functions.range(of: "cmux_ssh_auth_run_cleanup_transactions || exit 0")
        )

        #expect(claimAcquisition.lowerBound < cancellationPublication.lowerBound)
        #expect(claimAcquisition.lowerBound < cleanupTransaction.lowerBound)
    }

    @Test func failedOwnershipHandoffUsesBoundedBackgroundOwner() throws {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()
        let workerStart = try #require(
            functions.range(of: "cmux_ssh_auth_background_state=")
        )
        let workerEnd = try #require(
            functions.range(
                of: "cmux_ssh_auth_background_owner_pid=$!",
                range: workerStart.lowerBound..<functions.endIndex
            )
        )
        let worker = functions[workerStart.lowerBound..<workerEnd.upperBound]

        #expect(functions.contains("cmux_ssh_auth_handoff_deadline_millis"))
        #expect(functions.contains("cmux_ssh_auth_handoff_attempt"))
        #expect(functions.contains("cmux_ssh_auth_background_owner_pid=$!"))
        #expect(functions.contains("cmux_ssh_auth_durable_cleanup_pending=1"))
        #expect(worker.contains("cmux_ssh_auth_background_attempt"))
        #expect(worker.contains("-lt 8"))
        #expect(!worker.contains("while :; do"))
        #expect(worker.contains("cmux_ssh_auth_publish_current_worker"))
        #expect(functions.contains("cmux_ssh_auth_recorded_process_is_live"))
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func workerKillRevalidatesStableIdentity(shellPath: String) throws {
        let functions = SSHForegroundAuthenticationRetryPolicy()
            .processTreeTerminationShellFunction()
        let command = """
        \(functions)
        ( trap '' HUP INT TERM; while :; do /bin/sleep 30; done ) &
        cmux_test_worker_pid=$!
        trap '/bin/kill -KILL "$cmux_test_worker_pid" >/dev/null 2>&1 || true; wait "$cmux_test_worker_pid" 2>/dev/null || true' EXIT
        cmux_test_worker_identity=$(cmux_ssh_auth_stable_identity \
          "$cmux_test_worker_pid") || exit 99
        if cmux_ssh_auth_kill_worker_if_identity_matches \
          "$cmux_test_worker_pid" "${cmux_test_worker_identity}_stale"; then exit 98; fi
        /bin/kill -0 "$cmux_test_worker_pid" >/dev/null 2>&1 || exit 97
        if cmux_ssh_auth_kill_worker_if_identity_matches \
          "$cmux_test_worker_pid" ""; then exit 96; fi
        /bin/kill -0 "$cmux_test_worker_pid" >/dev/null 2>&1 || exit 95
        cmux_ssh_auth_kill_worker_if_identity_matches \
          "$cmux_test_worker_pid" "$cmux_test_worker_identity" || exit 94
        wait "$cmux_test_worker_pid" 2>/dev/null || true
        if /bin/kill -0 "$cmux_test_worker_pid" >/dev/null 2>&1; then exit 93; fi
        trap - EXIT
        """

        let result = try runShellCommand(command, environment: [:], shellPath: shellPath)

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
        #expect(!functions.contains("/bin/kill -KILL \"$cmux_ssh_auth_reaper_pid\""))
        #expect(!functions.contains("/bin/kill -KILL \"$cmux_ssh_auth_recovery_sweep_pid\""))
        #expect(!functions.contains("/bin/kill -KILL \"$cmux_ssh_auth_background_owner_pid\""))
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func cleanupRetainsAcknowledgedUnpublishedHandoff(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-acknowledged-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let cleanupBody = SSHForegroundAuthenticationRetryPolicy()
            .authenticationGroupDirectoryCleanupShellBody(terminatesPublishedGroup: false)
        let command = """
        cmux_test_group="$CMUX_SSH_AUTH_GROUP_DIR"
        : > "$CMUX_SSH_AUTH_GROUP_DIR/handoff.owner"
        cmux_ssh_auth_recorded_process_is_live() {
          test "$1" = "$cmux_test_group/handoff.owner"
        }
        cmux_ssh_schedule_failed_auth_group_recovery() { :; }
        \(cleanupBody)
        test -d "$cmux_test_group" || exit 99
        test -f "$cmux_test_group/handoff.owner" || exit 98
        """

        let result = try runShellCommand(
            command,
            environment: ["CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func durablePendingHandoffResumesBoundedTreeCleanup(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-pending-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.pending",
            isDirectory: true
        )
        let calls = root.appendingPathComponent("calls")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        try Data().write(to: groupDirectory.appendingPathComponent("handoff-pending"))
        try "101 1 777 Thu_Jan_1_00:00:00_1970\n".write(
            to: groupDirectory.appendingPathComponent("unpublished.root"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_force_unpublished_process_tree() {
          printf '%s\n' "$*" > "$CMUX_TEST_CALLS"
        }
        cmux_ssh_auth_resume_pending_handoff "$CMUX_TEST_GROUP" || exit 99
        /usr/bin/grep -Fqx '101 1 777 Thu_Jan_1_00:00:00_1970' \
          "$CMUX_TEST_CALLS" || exit 98
        test ! -d "$CMUX_TEST_GROUP" || exit 97
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_CALLS": calls.path,
                "CMUX_TEST_GROUP": groupDirectory.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func cleanupRetryRetainsReparentedOwnedIdentity(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-reparented-owned-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent(
            "cmux-ssh-auth-group.published",
            isDirectory: true
        )
        let retained = root.appendingPathComponent("retained")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_identity() {
          test "$1" = 101 || return 1
          printf '1|777777|Thu_Jan_1_00:00:00_1970\n'
        }
        cmux_ssh_auth_cleanup_claim() { return 0; }
        cmux_ssh_auth_cleanup_claim_is_current() { return 0; }
        cmux_ssh_auth_cleanup_claim_release() { :; }
        cmux_ssh_auth_resume_signaled_processes() { return 0; }
        cmux_ssh_auth_run_cleanup_transactions() {
          printf '202 9 888888 S Thu Jan 1 00:00:00 1970\n' \
            > "$cmux_ssh_auth_process_snapshot"
          cmux_ssh_auth_expand_owned_processes \
            "$cmux_ssh_auth_process_snapshot" || return 1
          /usr/bin/grep -Fqx \
            '202 9 888888 Thu_Jan_1_00:00:00_1970 S' \
            "$cmux_ssh_auth_owned_processes" || return 1
          : > "$CMUX_TEST_RETAINED"
        }
        printf '101|777777|Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        printf '202 1 888888 Thu_Jan_1_00:00:00_1970 R\n' \
          > "$CMUX_SSH_AUTH_GROUP_DIR/owned"
        cmux_ssh_terminate_owned_auth_group 999999
        test -e "$CMUX_TEST_RETAINED" || exit 99
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_RETAINED": retained.path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func concurrentCleanupCannotEnterSharedTransaction(shellPath: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ssh-auth-cleanup-claim-\(UUID().uuidString)",
            isDirectory: true
        )
        let groupDirectory = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try createSecureGroupDirectory(at: groupDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_test_real_identity() {
          cmux_test_kernel_record=$(cmux_ssh_auth_kernel_process_identity "$1") || return 1
          cmux_test_parent=${cmux_test_kernel_record%%|*}
          cmux_test_remainder=${cmux_test_kernel_record#*|}
          cmux_test_group=${cmux_test_remainder%%|*}
          cmux_test_remainder=${cmux_test_remainder#*|}
          cmux_test_status=${cmux_test_remainder%%|*}
          cmux_test_started=${cmux_test_remainder#*|}
          printf '%s|%s|%s\n' "$cmux_test_parent" "$cmux_test_group" "$cmux_test_started"
        }
        cmux_ssh_auth_identity() {
          if [ "$1" = 101 ]; then
            printf '1|777777|Thu_Jan_1_00:00:00_1970\n'
          else
            cmux_test_real_identity "$1"
          fi
        }
        cmux_ssh_auth_now_millis() { printf '1000\n'; }
        cmux_ssh_auth_run_cleanup_transactions() {
          if /bin/mkdir "$CMUX_TEST_TRANSACTION_GUARD" 2>/dev/null; then
            : > "$CMUX_TEST_FIRST_READY"
            cmux_test_release_attempt=0
            while [ ! -e "$CMUX_TEST_RELEASE_FIRST" ] && \
              [ "$cmux_test_release_attempt" -lt 300 ]; do
              /bin/sleep 0.01
              cmux_test_release_attempt=$((cmux_test_release_attempt + 1))
            done
            /bin/rmdir "$CMUX_TEST_TRANSACTION_GUARD" 2>/dev/null || true
            return 0
          fi
          : > "$CMUX_TEST_OVERLAP"
          return 0
        }
        printf '101|777777|Thu_Jan_1_00:00:00_1970\n' \
          > "$CMUX_SSH_AUTH_GROUP_DIR/identity"
        cmux_ssh_terminate_owned_auth_group 999999 &
        cmux_test_first_cleanup=$!
        cmux_test_ready_attempt=0
        while [ ! -e "$CMUX_TEST_FIRST_READY" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -e "$CMUX_TEST_FIRST_READY" || exit 98
        cmux_ssh_terminate_owned_auth_group 999999 &
        cmux_test_second_cleanup=$!
        wait "$cmux_test_second_cleanup" || exit 97
        : > "$CMUX_TEST_RELEASE_FIRST"
        wait "$cmux_test_first_cleanup" || exit 96
        test ! -e "$CMUX_TEST_OVERLAP" || exit 95
        """

        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_SSH_AUTH_GROUP_DIR": groupDirectory.path,
                "CMUX_TEST_FIRST_READY": root.appendingPathComponent("first-ready").path,
                "CMUX_TEST_OVERLAP": root.appendingPathComponent("overlap").path,
                "CMUX_TEST_RELEASE_FIRST": root.appendingPathComponent("release-first").path,
                "CMUX_TEST_TRANSACTION_GUARD": root.appendingPathComponent("transaction.guard").path,
                "TMPDIR": root.path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func cleanupTransactionReusesPostStopSnapshotAndChecksCompletion(shellPath: String) throws {
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
        test "$cmux_test_snapshot_calls" -eq 2 || exit 98
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
    func cleanupTransactionsContinueAfterCommittedPartialBatch(shellPath: String) throws {
        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_freeze_and_force_owned_processes() {
          cmux_test_transaction_calls=$((cmux_test_transaction_calls + 1))
          if [ "$cmux_test_transaction_calls" -eq 1 ]; then return 2; fi
          return 0
        }
        cmux_ssh_auth_resume_signaled_processes() {
          : > "$CMUX_TEST_UNEXPECTED_ROLLBACK"
          return 0
        }
        cmux_test_transaction_calls=0
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        cmux_ssh_auth_run_cleanup_transactions || exit 99
        test "$cmux_test_transaction_calls" -eq 2 || exit 98
        test ! -e "$CMUX_TEST_UNEXPECTED_ROLLBACK" || exit 97
        """

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-partial-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_UNEXPECTED_ROLLBACK": root.appendingPathComponent("rollback").path,
            ],
            shellPath: shellPath
        )

        #expect(result.status == 0, "Shell failed: \(result.standardError)")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func cleanupRetryResumesPreservedStopJournalBeforeReset(shellPath: String) throws {
        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        cmux_ssh_auth_deadline_allows_work() { return 0; }
        cmux_ssh_auth_freeze_and_force_owned_processes() {
          cmux_test_transaction_calls=$((cmux_test_transaction_calls + 1))
          printf '%s\n' "$cmux_test_transaction_calls" > "$CMUX_TEST_TRANSACTION_CALLS"
          if [ "$cmux_test_transaction_calls" -eq 1 ]; then
            printf '101 11 Thu_Jan_1_00:00:00_1970\n' \
              > "$cmux_ssh_auth_signaled_groups"
            printf '101 1 11 Thu_Jan_1_00:00:00_1970\n' \
              > "$cmux_ssh_auth_signaled_processes"
            return 1
          fi
          test -e "$CMUX_TEST_RESUMED" || return 1
          test ! -s "$cmux_ssh_auth_signaled_groups" || return 1
          test ! -s "$cmux_ssh_auth_signaled_processes" || return 1
          return 0
        }
        cmux_ssh_auth_resume_signaled_processes() {
          cmux_test_resume_calls=$((cmux_test_resume_calls + 1))
          printf '%s\n' "$cmux_test_resume_calls" > "$CMUX_TEST_RESUME_CALLS"
          if [ "$cmux_test_resume_calls" -eq 1 ]; then return 1; fi
          /usr/bin/grep -Fxq '101 11 Thu_Jan_1_00:00:00_1970' \
            "$cmux_ssh_auth_signaled_groups" || return 1
          /usr/bin/grep -Fxq '101 1 11 Thu_Jan_1_00:00:00_1970' \
            "$cmux_ssh_auth_signaled_processes" || return 1
          : > "$CMUX_TEST_RESUMED"
        }
        cmux_test_transaction_calls=0
        cmux_test_resume_calls=0
        cmux_ssh_auth_frozen_processes="$CMUX_TEST_FROZEN"
        cmux_ssh_auth_signaled_groups="$CMUX_TEST_SIGNALED_GROUPS"
        cmux_ssh_auth_signaled_processes="$CMUX_TEST_SIGNALED_PIDS"
        if cmux_ssh_auth_run_cleanup_transactions; then exit 99; fi
        cmux_ssh_auth_run_cleanup_transactions || exit 98
        test "$(/bin/cat "$CMUX_TEST_TRANSACTION_CALLS")" -eq 2 || exit 97
        test "$(/bin/cat "$CMUX_TEST_RESUME_CALLS")" -eq 2 || exit 96
        test -e "$CMUX_TEST_RESUMED" || exit 95
        """

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-preserved-stop-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runShellCommand(
            command,
            environment: [
                "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
                "CMUX_TEST_RESUMED": root.appendingPathComponent("resumed").path,
                "CMUX_TEST_RESUME_CALLS": root.appendingPathComponent("resume-calls").path,
                "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
                "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
                "CMUX_TEST_TRANSACTION_CALLS": root.appendingPathComponent("transaction-calls").path,
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
        cmux_test_victim_identity=$(cmux_ssh_auth_stopped_identity \
          "$cmux_test_victim_pid") || exit 96
        cmux_test_victim_parent=${cmux_test_victim_identity%%|*}
        cmux_test_victim_remainder=${cmux_test_victim_identity#*|}
        cmux_test_victim_group=${cmux_test_victim_remainder%%|*}
        cmux_test_victim_started=${cmux_test_victim_remainder#*|}
        case "$cmux_test_victim_pid:$cmux_test_victim_parent:$cmux_test_victim_group:$cmux_test_victim_started" in
          *[!A-Za-z0-9_:]*|:*|*:) exit 95 ;;
        esac
        printf '%s %s %s T %s\n' "$cmux_test_victim_pid" \
          "$cmux_test_victim_parent" "$cmux_test_victim_group" \
          "$cmux_test_victim_started" > "$CMUX_TEST_SNAPSHOT" || exit 94
        printf '%s %s %s %s T\n' "$cmux_test_victim_pid" \
          "$cmux_test_victim_parent" "$cmux_test_victim_group" \
          "$cmux_test_victim_started" > "$CMUX_TEST_FROZEN" || exit 93
        /bin/cp "$CMUX_TEST_FROZEN" "$CMUX_TEST_OWNED" || exit 92
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
        cmux_ssh_auth_force_frozen_processes "$CMUX_TEST_SNAPSHOT" || exit 90
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
        let groupRecord = root.appendingPathComponent("group-record")
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
            if let groupID = processGroupID(in: groupRecord) {
                Darwin.kill(-groupID, SIGKILL)
            }
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
        test -s "$CMUX_SSH_AUTH_GROUP_DIR/identity" || exit 95
        /bin/cp "$CMUX_SSH_AUTH_GROUP_DIR/identity" \
          "$CMUX_TEST_GROUP_RECORD" || exit 94
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
            "CMUX_TEST_GROUP_RECORD": groupRecord.path,
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
        let groupID = try #require(processGroupID(in: groupRecord))

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
        #expect(
            Darwin.kill(-groupID, 0) != 0,
            "Foreground authentication cleanup left process group \(groupID) alive"
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

    private func freezeIdentityTestEnvironment(root: URL) -> [String: String] {
        [
            "CMUX_TEST_FROZEN": root.appendingPathComponent("frozen").path,
            "CMUX_TEST_GROUPS": root.appendingPathComponent("groups").path,
            "CMUX_TEST_INDIVIDUALS": root.appendingPathComponent("individuals").path,
            "CMUX_TEST_ORDERED": root.appendingPathComponent("ordered").path,
            "CMUX_TEST_OWNED": root.appendingPathComponent("owned").path,
            "CMUX_TEST_OWNED_NEXT": root.appendingPathComponent("owned.next").path,
            "CMUX_TEST_POSTSTOP_SNAPSHOT": root.appendingPathComponent("processes.stopped").path,
            "CMUX_TEST_PROCESS_SNAPSHOT": root.appendingPathComponent("processes").path,
            "CMUX_TEST_SIGNALED_GROUPS": root.appendingPathComponent("signaled.groups").path,
            "CMUX_TEST_SIGNALED_PIDS": root.appendingPathComponent("signaled.pids").path,
            "CMUX_TEST_SIGNALS": root.appendingPathComponent("signals").path,
        ]
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
