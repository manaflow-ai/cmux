import CMUXAgentLaunch
import Foundation
import Testing

@Suite("AgentResumeShellScriptBuilder")
struct AgentResumeShellScriptBuilderTests {
    @Test("Disabled retry policy emits the plain child-shell command")
    func disabledRetryPolicyUsesPlainCommand() {
        let lines = AgentResumeShellScriptBuilder().commandThenReturnLines(
            command: "codex resume SID",
            workingDirectory: "/tmp/project"
        )

        #expect(lines.contains(#"  zsh|bash) "$_cmux_resume_shell" -lic 'codex resume SID' ;;"#))
        #expect(!lines.contains { $0.contains("CMUX_AGENT_RESUME_RETRY_LIMIT") })
        #expect(lines.contains(#"{ cd -- '/tmp/project' 2>/dev/null || true; }"#))
        #expect(lines.last == #"exec -l "$_cmux_resume_shell""#)
    }

    @Test("Codex retry policy emits a bounded startup-failure loop")
    func codexRetryPolicyUsesBoundedStartupFailureLoop() {
        let lines = AgentResumeShellScriptBuilder().commandThenReturnLines(
            command: "codex resume SID",
            workingDirectory: "/tmp/project",
            retryPolicy: .codexStateDatabaseLock
        )
        let script = lines.joined(separator: "\n")

        #expect(script.contains(#"_cmux_resume_retry_limit="${CMUX_AGENT_RESUME_RETRY_LIMIT:-3}""#))
        #expect(script.contains(#"_cmux_resume_retry_delay="${CMUX_AGENT_RESUME_RETRY_DELAY_SECONDS:-0.250}""#))
        #expect(script.contains(#"_cmux_resume_retry_startup_seconds="${CMUX_AGENT_RESUME_RETRY_STARTUP_SECONDS:-5}""#))
        #expect(script.contains(#"/usr/bin/script -q -F /dev/null"#))
        #expect(script.contains(#"if [ "$_cmux_resume_elapsed" -gt "$_cmux_resume_retry_startup_seconds" ]; then"#))
        #expect(!script.contains("_cmux_resume_log"))
        #expect(script.contains(#"if [ "$_cmux_resume_retry" -ge "$_cmux_resume_retry_limit" ]; then"#))
        #expect(lines.contains(#"{ cd -- '/tmp/project' 2>/dev/null || true; }"#))
    }

    @Test("Generated Codex retry launcher runs until the transient lock clears")
    func generatedRetryLauncherRunsUntilLockClears() throws {
        let harness = try RetryLauncherHarness.make()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        try harness.writeFakeCodex(succeedOnAttempt: 2)
        let result = try harness.runLauncher()

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try harness.attemptCount() == 2)
        #expect(result.stdout.contains("resume-ok attempt=2"))
        #expect(try harness.fallbackWorkingDirectory() == harness.workingDirectory.path)
    }

    @Test("Generated Codex retry launcher stops after the retry bound")
    func generatedRetryLauncherStopsAtBound() throws {
        let harness = try RetryLauncherHarness.make()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        try harness.writeFakeCodex(succeedOnAttempt: nil)
        let result = try harness.runLauncher()

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try harness.attemptCount() == 4)
        #expect(!result.stdout.contains("resume-ok"))
        #expect(try harness.fallbackWorkingDirectory() == harness.workingDirectory.path)
    }
}

private struct RetryLauncherHarness {
    let root: URL
    let workingDirectory: URL
    let homeDirectory: URL
    let shellURL: URL
    let codexURL: URL
    let attemptCountURL: URL
    let fallbackCwdURL: URL
    let launcherURL: URL

    static func make() throws -> RetryLauncherHarness {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-launch-retry-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let shellURL = binDirectory.appendingPathComponent("cmux-test-shell", isDirectory: false)
        let codexURL = binDirectory.appendingPathComponent("codex", isDirectory: false)
        let attemptCountURL = root.appendingPathComponent("attempts.txt", isDirectory: false)
        let fallbackCwdURL = root.appendingPathComponent("fallback-cwd.txt", isDirectory: false)
        let launcherURL = root.appendingPathComponent("launcher.zsh", isDirectory: false)

        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let harness = RetryLauncherHarness(
            root: root,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            shellURL: shellURL,
            codexURL: codexURL,
            attemptCountURL: attemptCountURL,
            fallbackCwdURL: fallbackCwdURL,
            launcherURL: launcherURL
        )
        try harness.writeFallbackLoggingShell()
        try harness.writeLauncher()
        return harness
    }

    func writeFakeCodex(succeedOnAttempt: Int?) throws {
        let successCondition: String
        if let succeedOnAttempt {
            successCondition = #"""
if [ "$count" -ge \#(succeedOnAttempt) ]; then
  echo "resume-ok attempt=$count"
  exit 0
fi
"""#
        } else {
            successCondition = ""
        }

        let script = #"""
#!/bin/sh
count_file=\#(shellSingleQuoted(attemptCountURL.path))
count=0
if [ -r "$count_file" ]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
\#(successCondition)
echo "Codex couldn't start because another Codex process is using its local data." >&2
echo "Location: ${HOME}/.codex/state_5.sqlite" >&2
echo "Cause: failed to initialize state runtime: error returned from database: (code: 5) database is locked" >&2
exit 1
"""#
        try script.write(to: codexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexURL.path)
    }

    func runLauncher() throws -> LauncherResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcherURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_AGENT_RESUME_RETRY_DELAY_SECONDS"] = "0"
        environment["CMUX_AGENT_RESUME_RETRY_LIMIT"] = "3"
        environment["CMUX_AGENT_RESUME_RETRY_STARTUP_SECONDS"] = "5"
        environment["HOME"] = homeDirectory.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["SHELL"] = shellURL.path
        environment["ZDOTDIR"] = homeDirectory.path
        process.environment = environment

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        return LauncherResult(
            status: process.terminationStatus,
            stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    func attemptCount() throws -> Int {
        let value = try String(contentsOf: attemptCountURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int(value))
    }

    func fallbackWorkingDirectory() throws -> String {
        try String(contentsOf: fallbackCwdURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeLauncher() throws {
        let quotedWorkingDirectory = shellSingleQuoted(workingDirectory.path)
        let command = "{ cd -- \(quotedWorkingDirectory) 2>/dev/null || [ ! -d \(quotedWorkingDirectory) ]; } && \(shellSingleQuoted(codexURL.path)) resume SID"
        let lines = [
            "#!/bin/zsh",
            "rm -f -- \"$0\" 2>/dev/null || true",
        ] + AgentResumeShellScriptBuilder().commandThenReturnLines(
            command: command,
            workingDirectory: workingDirectory.path,
            retryPolicy: .codexStateDatabaseLock
        )
        try (lines.joined(separator: "\n") + "\n").write(to: launcherURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
    }

    private func writeFallbackLoggingShell() throws {
        let script = #"""
#!/bin/sh
if [ "$1" = "-c" ] || [ "$1" = "-lc" ] || [ "$1" = "-lic" ]; then
  flag="$1"
  shift
  exec /bin/zsh "$flag" "$1"
fi
pwd > \#(shellSingleQuoted(fallbackCwdURL.path))
exit 0
"""#
        try script.write(to: shellURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shellURL.path)
    }
}

private struct LauncherResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
