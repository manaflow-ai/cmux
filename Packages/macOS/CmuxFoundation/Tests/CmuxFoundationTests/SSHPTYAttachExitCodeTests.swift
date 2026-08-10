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
        ] + SSHPTYAttachExitCode.retryLoopLines(
            command: Self.shellQuote(attach.path),
            reauthenticates: true
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

    // Regression for #9443: env-assignment prefixes are only legal before a
    // simple command, so a compound attach command used to produce
    // "syntax error near unexpected token `then'".
    @Test("retry loop stays valid POSIX shell for compound attach commands")
    func retryLoopAcceptsCompoundAttachCommands() throws {
        let compoundCommand = [
            "if [ \"$cmux_ssh_attach_no_progress_retry\" -gt 0 ]; then :; fi",
            "exit 0",
        ].joined(separator: "\n")
        let script = SSHPTYAttachExitCode.retryLoopLines(
            command: compoundCommand,
            reauthenticates: false
        ).joined(separator: "\n")
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pty-retry-syntax-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try (script + "\n").write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", scriptURL.path]
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "\(stderr)\n\(script)")
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

    private static func writeExecutable(_ url: URL, _ source: String) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
