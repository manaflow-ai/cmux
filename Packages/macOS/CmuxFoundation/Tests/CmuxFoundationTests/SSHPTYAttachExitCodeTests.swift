import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH PTY attach exit code")
struct SSHPTYAttachExitCodeTests {
    @Test("structured daemon capacity retries without requesting authentication")
    func structuredUnavailableRetriesWithoutAuthentication() {
        let classified = SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
            code: "unavailable",
            message: "remote PTY attach failed"
        )

        #expect(classified.rawValue == 251)
        #expect(classified.isWrapperRetryable)
        #expect(SSHPTYAttachExitCode.retryableTransient.rawValue == 255)
        #expect(!SSHPTYAttachExitCode.daemonNotReady.requiresForegroundAuthentication)
        #expect(SSHPTYAttachExitCode.authenticationRequired.requiresForegroundAuthentication)
    }

    @Test("capacity retries keep authentication ownership idle")
    func capacityRetryDoesNotReauthenticate() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pty-capacity-\(UUID().uuidString)", isDirectory: true)
        let attach = root.appendingPathComponent("attach")
        let sleep = root.appendingPathComponent("sleep")
        let attempts = root.appendingPathComponent("attempts")
        let authAttempts = root.appendingPathComponent("auth-attempts")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeExecutable(
            attach,
            """
            #!/bin/sh
            count=$(cat "$CMUX_TEST_ATTEMPTS" 2>/dev/null || printf 0)
            count=$((count + 1))
            printf '%s' "$count" > "$CMUX_TEST_ATTEMPTS"
            if [ "$count" -eq 1 ]; then exit 251; fi
            exit 1
            """
        )
        try Self.writeExecutable(sleep, "#!/bin/sh\nexit 0")

        let retryScript = ([
            "cmux_ssh_attach_foreground_auth() { printf x >> \"$CMUX_TEST_AUTH_ATTEMPTS\"; }",
        ] + SSHPTYAttachRetryScriptBuilder().lines(
            command: Self.shellQuote(attach.path),
            reauthenticates: true,
            initialAuthentication: false
        )).joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", retryScript]
        process.environment = [
            "PATH": "\(root.path):/usr/bin:/bin",
            "CMUX_TEST_ATTEMPTS": attempts.path,
            "CMUX_TEST_AUTH_ATTEMPTS": authAttempts.path,
            "CMUX_SSH_RECONNECT_DELAY_SECONDS": "1",
            "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "1",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 1)
        #expect(try String(contentsOf: attempts, encoding: .utf8) == "2")
        #expect(!fileManager.fileExists(atPath: authAttempts.path))
    }

    @Test("A no-progress retry resets terminal reporting modes before reattaching")
    func noProgressRetryResetsTerminalModesBeforeReattaching() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-no-progress-terminal-reset-\(UUID().uuidString)")
        let attemptFile = root.appendingPathComponent("attempts")
        let scriptFile = root.appendingPathComponent("loop.sh")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let retryLines = SSHPTYAttachExitCode.noProgressRetryLoopLines(
            command: "cmux_test_attach"
        )
        try Self.writeExecutable(
            scriptFile,
            ([
                "#!/bin/sh",
                "cmux_test_attach() {",
                "  count=$(cat \"$CMUX_TEST_ATTEMPT_FILE\" 2>/dev/null || printf 0)",
                "  count=$((count + 1))",
                "  printf '%s' \"$count\" > \"$CMUX_TEST_ATTEMPT_FILE\"",
                "  printf 'attempt:%s\\n' \"$count\" >&2",
                "  if [ \"$count\" -eq 1 ]; then return \(SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue); fi",
                "  return 0",
                "}",
            ] + retryLines).joined(separator: "\n")
        )

        let transcriptPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "-F", "/dev/null", "/bin/sh", scriptFile.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_ATTEMPT_FILE": attemptFile.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = transcriptPipe
        process.standardError = transcriptPipe

        try process.run()
        let transcriptData = transcriptPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let transcript = String(data: transcriptData, encoding: .utf8) ?? ""

        #expect(process.terminationStatus == 0, Comment(rawValue: transcript))
        let secondAttempt = transcript.range(of: "attempt:2")
        #expect(secondAttempt != nil, Comment(rawValue: transcript))
        let requiredResets = [
            "\u{1B}[?1004l", // focus reporting
            "\u{1B}[?1000l", // mouse reporting
            "\u{1B}[?2004l", // bracketed paste
            "\u{1B}[999<u", // Kitty keyboard stack
            "\u{1B}[0;1=u", // Kitty keyboard flags
            "\u{1B}[?2048l", // in-band resize reports
            "\u{1B}[?2026l", // synchronized output
        ]
        for reset in requiredResets {
            let resetRange = transcript.range(of: reset)
            #expect(resetRange != nil, Comment(rawValue: transcript))
            if let resetRange, let secondAttempt {
                #expect(resetRange.lowerBound < secondAttempt.lowerBound)
            }
        }
    }

    @Test("lifecycle codes retain precedence over transient-looking messages")
    func lifecycleCodesRetainPrecedence() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "pty_session_not_found",
                message: "service unavailable"
            ) == .sessionNotFound
        )
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "pty_lifecycle_closed",
                message: "service unavailable"
            ) == .fatal
        )
    }

    @Test("unrelated codes containing unavailable remain fatal")
    func unavailableMustBeExact() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "service_unavailable",
                message: "remote PTY attach failed"
            ) == .fatal
        )
    }

    @Test("replayed scrollback does not count as live bridge progress")
    func replayedScrollbackDoesNotCountAsLiveProgress() {
        var progress = SSHPTYAttachOutputProgress(replayBytes: 6)

        progress.recordOutput(byteCount: 4)
        #expect(progress.replayBytesRemaining == 2)
        #expect(!progress.receivedLiveOutput)

        progress.recordOutput(byteCount: 4)
        #expect(progress.replayBytesRemaining == 0)
        #expect(progress.receivedLiveOutput)
    }

    @Test("managed reconnects can hide only the declared replay")
    func managedReconnectSuppressesReplayBytes() {
        var progress = SSHPTYAttachOutputProgress(replayBytes: 6)
        let output = progress.terminalOutput(
            from: Data("promptlive".utf8),
            suppressingReplay: true
        )

        #expect(String(decoding: output, as: UTF8.self) == "live")
        #expect(progress.replayBytesRemaining == 0)
        #expect(progress.receivedLiveOutput)
    }

    @Test("managed reconnects preserve output appended after the prior snapshot")
    func managedReconnectPreservesAppendedReplayOutput() {
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 10,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(
                of: Data("oldold".utf8)
            )
        )
        let output = progress.terminalOutput(
            from: Data("oldoldnew!".utf8),
            suppressingReplay: true
        )

        #expect(String(decoding: output, as: UTF8.self) == "new!")
        #expect(progress.replayBytesRemaining == 0)
        #expect(progress.receivedLiveOutput)
    }

    @Test("managed reconnects forward a replacement snapshot after rollover")
    func managedReconnectForwardsRolloverSnapshot() {
        let previousFingerprint = SSHPTYAttachOutputProgress.fingerprint(
            of: Data("oldold".utf8)
        )
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 10,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: previousFingerprint
        )
        let output = progress.terminalOutput(
            from: Data("newnewnew!".utf8),
            suppressingReplay: true
        )

        #expect(String(decoding: output, as: UTF8.self) == "newnewnew!")
        #expect(progress.receivedLiveOutput)
    }

    @Test("managed reconnects retain buffered bytes when rollover validation spans chunks")
    func managedReconnectRetainsFragmentedRolloverSnapshot() {
        let previousFingerprint = SSHPTYAttachOutputProgress.fingerprint(
            of: Data("oldold".utf8)
        )
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 10,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: previousFingerprint
        )
        let firstChunk = progress.terminalOutput(
            from: Data("new".utf8),
            suppressingReplay: true
        )
        let secondChunk = progress.terminalOutput(
            from: Data("newnew!".utf8),
            suppressingReplay: true
        )

        #expect(firstChunk.isEmpty)
        #expect(String(decoding: secondChunk, as: UTF8.self) == "newnewnew!")
        #expect(progress.receivedLiveOutput)
    }

    @Test("managed reconnects retain suffix after a fragmented matching prefix")
    func managedReconnectRetainsFragmentedMatchingSuffix() {
        let previousFingerprint = SSHPTYAttachOutputProgress.fingerprint(
            of: Data("oldold".utf8)
        )
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 10,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: previousFingerprint
        )
        _ = progress.terminalOutput(
            from: Data("old".utf8),
            suppressingReplay: true
        )
        let suffix = progress.terminalOutput(
            from: Data("oldnewnew!".utf8),
            suppressingReplay: true
        )

        #expect(String(decoding: suffix, as: UTF8.self) == "newnew!")
        #expect(progress.receivedLiveOutput)
    }

    @Test("an incomplete replay candidate is discarded when another attach will retry")
    func managedReconnectDiscardsIncompleteCandidateForRetry() {
        let previousFingerprint = SSHPTYAttachOutputProgress.fingerprint(
            of: Data("oldold".utf8)
        )
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 10,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: previousFingerprint
        )
        _ = progress.terminalOutput(
            from: Data("new".utf8),
            suppressingReplay: true
        )

        #expect(progress.finishPendingReplay(discarding: true).isEmpty)
    }

    @Test("a partially delivered verified replay can flush on a final attach")
    func managedReconnectFlushesBufferedSuffixOnFinalAttach() {
        let previousFingerprint = SSHPTYAttachOutputProgress.fingerprint(
            of: Data("oldold".utf8)
        )
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 10,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: previousFingerprint
        )
        _ = progress.terminalOutput(
            from: Data("oldoldnew".utf8),
            suppressingReplay: true
        )

        #expect(String(decoding: progress.finishPendingReplay(), as: UTF8.self) == "new")
    }

    private static func writeExecutable(_ url: URL, _ source: String) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
