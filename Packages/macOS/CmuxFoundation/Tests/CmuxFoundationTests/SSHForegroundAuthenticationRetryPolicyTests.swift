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
        let signalLog = root.appendingPathComponent("signal.log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        trap '' HUP INT
        trap 'printf "%s\\n" term > "$CMUX_TEST_SIGNAL_LOG"' TERM
        printf '%s\\n' "$$" > "$CMUX_TEST_LEAF_PID"
        while :; do /bin/sleep 30; done
        """.write(to: leafScript, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leafScript.path)

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        ( /bin/sh "$CMUX_TEST_LEAF_SCRIPT" & wait $! ) &
        cmux_test_auth_root=$!
        cmux_test_ready_attempt=0
        while [ ! -s "$CMUX_TEST_LEAF_PID" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -s "$CMUX_TEST_LEAF_PID" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        test "$(/bin/cat "$CMUX_TEST_SIGNAL_LOG" 2>/dev/null || true)" = term
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_LEAF_SCRIPT": leafScript.path,
            "CMUX_TEST_LEAF_PID": leafPIDFile.path,
            "CMUX_TEST_SIGNAL_LOG": signalLog.path,
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
        #expect(try String(contentsOf: signalLog, encoding: .utf8) == "term\n")
        #expect(Darwin.kill(leafPID, 0) != 0)
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

    @Test func processTreeTerminationUsesOneOverallDeadline() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-deadline-\(UUID().uuidString)", isDirectory: true)
        let chainScript = root.appendingPathComponent("chain.sh")
        let readyMarker = root.appendingPathComponent("ready")
        let pidLog = root.appendingPathComponent("pids")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
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

        let command = """
        \(SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction())
        CMUX_TEST_CHAIN_DEPTH=24 /bin/sh "$CMUX_TEST_CHAIN_SCRIPT" &
        cmux_test_auth_root=$!
        cmux_test_ready_attempt=0
        while [ ! -f "$CMUX_TEST_READY_MARKER" ] && [ "$cmux_test_ready_attempt" -lt 300 ]; do
          /bin/sleep 0.01
          cmux_test_ready_attempt=$((cmux_test_ready_attempt + 1))
        done
        test -f "$CMUX_TEST_READY_MARKER" || exit 98
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_CHAIN_SCRIPT": chainScript.path,
            "CMUX_TEST_READY_MARKER": readyMarker.path,
            "CMUX_TEST_PID_LOG": pidLog.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        let startedAt = Date.now
        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture, timeout: 8)
        let elapsed = Date.now.timeIntervalSince(startedAt)

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
        #expect(!processIDs.contains(where: { Darwin.kill($0, 0) == 0 }))
    }

    @Test func terminatesReplacementSpawnedByAuthenticationTermHandler() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-replacement-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
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

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            trap '/usr/bin/nohup /bin/sh "$CMUX_TEST_REPLACEMENT_SCRIPT" </dev/null >/dev/null 2>&1 & exit 143' TERM
            : > "$CMUX_TEST_READY_MARKER"
            while :; do /bin/sleep 30; done
            """
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
        cmux_ssh_terminate_auth_process_tree "$cmux_test_auth_root" "$$"
        wait "$cmux_test_auth_root" 2>/dev/null || true
        cmux_test_replacement_attempt=0
        while [ ! -s "$CMUX_TEST_REPLACEMENT_PID" ] && [ "$cmux_test_replacement_attempt" -lt 100 ]; do
          /bin/sleep 0.01
          cmux_test_replacement_attempt=$((cmux_test_replacement_attempt + 1))
        done
        test -s "$CMUX_TEST_REPLACEMENT_PID"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_READY_MARKER": readyMarker.path,
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

        let replacementPID = try #require(Int32(
            String(contentsOf: replacementPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { Darwin.kill(replacementPID, SIGKILL) }
        let exitDeadline = Date.now.addingTimeInterval(1)
        while Darwin.kill(replacementPID, 0) == 0, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(process.terminationStatus == 0)
        #expect(Darwin.kill(replacementPID, 0) != 0)
    }

    @Test func restoresTerminalModesWhenTerminatingForegroundAuthenticationTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-auth-termios-\(UUID().uuidString)", isDirectory: true)
        let readyMarker = root.appendingPathComponent("ready")
        let signalLog = root.appendingPathComponent("signal.log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let policy = SSHForegroundAuthenticationRetryPolicy()
        let classifiedAuthentication = policy.classifyingTransientFailure(
            in: """
            trap '' HUP INT
            trap 'printf "%s\\n" term > "$CMUX_TEST_SIGNAL_LOG"; exit 143' TERM
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
            "CMUX_TEST_SIGNAL_LOG": signalLog.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrCapture = try makeStandardErrorCapture()
        defer { removeStandardErrorCapture(stderrCapture) }
        process.standardError = stderrCapture.handle

        try process.run()
        try waitForExit(process, stderrCapture: stderrCapture)

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: signalLog, encoding: .utf8) == "term\n")
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

        let diagnosticFiles = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ).filter {
            $0 != readyFile
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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
