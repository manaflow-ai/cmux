import CMUXAgentLaunch
import Foundation
import Testing

@Suite("CodexResumeRetryShell")
struct CodexResumeRetryShellTests {
    @Test("Retries transient lock after stderr is captured")
    func retriesTransientLockAfterCapturingStderr() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-retry-shell-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo with spaces", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attemptsURL = root.appendingPathComponent("attempts.txt", isDirectory: false)
        let recordURL = root.appendingPathComponent("record.txt", isDirectory: false)
        let fakeCodexURL = binDirectory.appendingPathComponent("codex fake", isDirectory: false)
        try """
        #!/bin/zsh
        attempt=0
        if [[ -r \(Self.shellSingleQuoted(attemptsURL.path)) ]]; then
          attempt="$(cat \(Self.shellSingleQuoted(attemptsURL.path)))"
        fi
        attempt=$((attempt + 1))
        print -r -- "$attempt" > \(Self.shellSingleQuoted(attemptsURL.path))
        if [[ "$attempt" -lt 3 ]]; then
          for index in {1..100}; do
            print -u2 "startup stderr line $index"
          done
          print -u2 "ERROR: failed to initialize sqlite state db at /Users/example/.codex/state_5.sqlite: (code: 5) database is locked"
          exit 1
        fi
        printf 'attempt=%s\\ncwd=%s\\nargs=%s\\n' "$attempt" "$PWD" "$*" > \(Self.shellSingleQuoted(recordURL.path))
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

        let command = [
            Self.shellSingleQuoted(fakeCodexURL.path),
            "resume",
            Self.shellSingleQuoted("session id"),
        ].joined(separator: " ")
        let wrapped = CodexResumeRetryShell(maxAttempts: 4).wrappedCommand(
            command,
            quote: Self.shellSingleQuoted
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "cd -- \(Self.shellSingleQuoted(workingDirectory.path)) && \(wrapped)",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "stderr: \(stderrText)")
        #expect(
            try String(contentsOf: attemptsURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "3"
        )
        let record = try String(contentsOf: recordURL, encoding: .utf8)
        #expect(record.contains("cwd=\(workingDirectory.path)\n"))
        #expect(record.contains("args=resume session id\n"))
    }

    @Test("Does not retry fast non-lock failure")
    func doesNotRetryFastNonLockFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-retry-shell-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attemptsURL = root.appendingPathComponent("attempts.txt", isDirectory: false)
        let fakeCodexURL = binDirectory.appendingPathComponent("codex fake", isDirectory: false)
        try """
        #!/bin/zsh
        attempt=0
        if [[ -r \(Self.shellSingleQuoted(attemptsURL.path)) ]]; then
          attempt="$(cat \(Self.shellSingleQuoted(attemptsURL.path)))"
        fi
        attempt=$((attempt + 1))
        print -r -- "$attempt" > \(Self.shellSingleQuoted(attemptsURL.path))
        print -u2 "ERROR: permission denied"
        exit 2
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

        let wrapped = CodexResumeRetryShell(maxAttempts: 4).wrappedCommand(
            Self.shellSingleQuoted(fakeCodexURL.path),
            quote: Self.shellSingleQuoted
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", wrapped]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 2, "stderr: \(stderrText)")
        #expect(
            try String(contentsOf: attemptsURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        )
    }

    @Test("Preserves TTY file descriptors for child")
    func preservesTTYFileDescriptorsForChild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-retry-shell-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordURL = root.appendingPathComponent("record.txt", isDirectory: false)
        let fakeCodexURL = binDirectory.appendingPathComponent("codex fake", isDirectory: false)
        try """
        #!/bin/zsh
        [[ -t 0 && -t 1 && -t 2 ]]
        tty_status=$?
        print -r -- "tty=$tty_status" > \(Self.shellSingleQuoted(recordURL.path))
        exit "$tty_status"
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

        let wrapped = CodexResumeRetryShell(maxAttempts: 4).wrappedCommand(
            Self.shellSingleQuoted(fakeCodexURL.path),
            quote: Self.shellSingleQuoted
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", wrapped]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "stderr: \(stderrText)")
        #expect(try String(contentsOf: recordURL, encoding: .utf8) == "tty=0\n")
    }

    @Test("Does not retry lock text after startup window")
    func doesNotRetryLockTextAfterStartupWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-retry-shell-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attemptsURL = root.appendingPathComponent("attempts.txt", isDirectory: false)
        let successURL = root.appendingPathComponent("success.txt", isDirectory: false)
        let fakeCodexURL = binDirectory.appendingPathComponent("codex fake", isDirectory: false)
        try """
        #!/bin/zsh
        attempt=0
        if [[ -r \(Self.shellSingleQuoted(attemptsURL.path)) ]]; then
          attempt="$(cat \(Self.shellSingleQuoted(attemptsURL.path)))"
        fi
        attempt=$((attempt + 1))
        print -r -- "$attempt" > \(Self.shellSingleQuoted(attemptsURL.path))
        if [[ "$attempt" -gt 1 ]]; then
          print -r -- "unexpected retry" > \(Self.shellSingleQuoted(successURL.path))
        fi
        print -u2 "ERROR: database is locked"
        exit 1
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

        let wrapped = CodexResumeRetryShell(maxAttempts: 4, startupWindowSeconds: 0).wrappedCommand(
            Self.shellSingleQuoted(fakeCodexURL.path),
            quote: Self.shellSingleQuoted
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", wrapped]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 1, "stderr: \(stderrText)")
        #expect(
            try String(contentsOf: attemptsURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        )
        #expect(!FileManager.default.fileExists(atPath: successURL.path))
    }

    @Test("Nested retry shell preserves caller working directory")
    func nestedRetryShellPreservesCallerWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-retry-shell-\(UUID().uuidString)", isDirectory: true)
        let expectedDirectory = root.appendingPathComponent("expected workspace", isDirectory: true)
        let profileDirectory = root.appendingPathComponent("profile cwd", isDirectory: true)
        let zDotDirectory = root.appendingPathComponent("zdotdir", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: expectedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zDotDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zprofileURL = zDotDirectory.appendingPathComponent(".zprofile", isDirectory: false)
        try "cd -- \(Self.shellSingleQuoted(profileDirectory.path))\n"
            .write(to: zprofileURL, atomically: true, encoding: .utf8)

        let recordURL = root.appendingPathComponent("record.txt", isDirectory: false)
        let fakeCodexURL = binDirectory.appendingPathComponent("codex fake", isDirectory: false)
        try """
        #!/bin/zsh
        printf 'cwd=%s\\n' "$PWD" > \(Self.shellSingleQuoted(recordURL.path))
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

        let wrapped = CodexResumeRetryShell(maxAttempts: 4).wrappedCommand(
            Self.shellSingleQuoted(fakeCodexURL.path),
            quote: Self.shellSingleQuoted
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "cd -- \(Self.shellSingleQuoted(expectedDirectory.path)) && \(wrapped)",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = zDotDirectory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "stderr: \(stderrText)")
        #expect(try String(contentsOf: recordURL, encoding: .utf8) == "cwd=\(expectedDirectory.path)\n")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
