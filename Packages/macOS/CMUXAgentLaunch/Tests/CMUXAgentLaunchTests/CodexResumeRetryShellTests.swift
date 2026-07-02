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

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
