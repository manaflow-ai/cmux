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

    private static func writeExecutable(_ url: URL, _ source: String) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
