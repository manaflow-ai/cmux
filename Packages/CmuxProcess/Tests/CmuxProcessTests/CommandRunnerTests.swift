import Foundation
import Testing

@testable import CmuxProcess

@Suite struct CommandRunnerTests {
    private let runner = CommandRunner()
    private let tempDir = FileManager.default.temporaryDirectory.path

    @Test func capturesStdoutAndCleanExit() async {
        let result = await runner.run(
            directory: tempDir,
            executable: "echo",
            arguments: ["hello world"],
            timeout: 10
        )
        #expect(result.executionError == nil)
        #expect(result.timedOut == false)
        #expect(result.exitStatus == 0)
        #expect(result.stdout == "hello world\n")
    }

    @Test func runStandardOutputReturnsTrimmableOutputOnCleanExit() async {
        let output = await runner.runStandardOutput(
            directory: tempDir,
            executable: "printf",
            arguments: ["%s", "token-value"],
            timeout: 10
        )
        #expect(output == "token-value")
    }

    @Test func capturesStderrAndNonZeroExit() async {
        let result = await runner.run(
            directory: tempDir,
            executable: "sh",
            arguments: ["-c", "echo oops 1>&2; exit 3"],
            timeout: 10
        )
        #expect(result.exitStatus == 3)
        #expect(result.timedOut == false)
        #expect(result.stderr == "oops\n")
        // Non-zero exit means the stdout-only convenience yields nil.
        #expect(result.executionError == nil)
    }

    @Test func nonZeroExitMakesRunStandardOutputNil() async {
        let output = await runner.runStandardOutput(
            directory: tempDir,
            executable: "sh",
            arguments: ["-c", "exit 1"],
            timeout: 10
        )
        #expect(output == nil)
    }

    @Test func timesOutLongRunningCommand() async {
        let start = Date()
        let result = await runner.run(
            directory: tempDir,
            executable: "sleep",
            arguments: ["10"],
            timeout: 0.3
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.timedOut == true)
        #expect(result.exitStatus == nil)
        // The deadline fired well before the 10s sleep would have finished.
        #expect(elapsed < 5)
    }

    @Test func timesOutPromptlyWhenDescendantKeepsPipesOpen() async {
        // A backgrounded grandchild inherits stdout/stderr and outlives the immediate
        // child, so the pipes never reach EOF at the deadline. The timeout result must
        // not wait on the pipe readers; otherwise `run` hangs until the grandchild exits.
        let start = Date()
        let result = await runner.run(
            directory: tempDir,
            executable: "sh",
            arguments: ["-c", "sleep 5 & wait"],
            timeout: 0.3
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.timedOut == true)
        #expect(result.exitStatus == nil)
        // Returns at the ~0.3s deadline, not after the 5s grandchild finishes.
        #expect(elapsed < 3)
    }

    @Test func timesOutWhenChildExitsEarlyButDescendantKeepsPipesOpen() async {
        // The immediate child (`sh`) exits almost immediately, but the backgrounded
        // grandchild inherits stdout/stderr and keeps a pipe open. The deadline must stay
        // armed after the child exits, otherwise `run` strands on the pipe readers with no
        // timeout left. (No `wait`, so `sh` returns before the 0.3s deadline.)
        let start = Date()
        let result = await runner.run(
            directory: tempDir,
            executable: "sh",
            arguments: ["-c", "sleep 5 &"],
            timeout: 0.3
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.timedOut == true)
        #expect(elapsed < 3)
    }

    @Test func zeroTimeoutTerminatesWithoutCrashing() async {
        // A 0s deadline fires the timer immediately; arming it only after launch (and
        // guarding terminate with isRunning) must yield a timed-out result rather than
        // calling terminate() on an unlaunched Process (which raises).
        let result = await runner.run(
            directory: tempDir,
            executable: "sleep",
            arguments: ["10"],
            timeout: 0
        )
        #expect(result.timedOut == true)
        #expect(result.exitStatus == nil)
    }

    @Test func handlesLargeOutputWithoutDeadlock() async {
        // ~1 MiB of output exceeds the pipe buffer; concurrent draining must avoid deadlock.
        let result = await runner.run(
            directory: tempDir,
            executable: "sh",
            arguments: ["-c", "yes ABCDEFGHIJ | head -n 100000"],
            timeout: 30
        )
        #expect(result.exitStatus == 0)
        #expect(result.timedOut == false)
        #expect((result.stdout?.count ?? 0) >= 100000)
    }

    @Test func resolvesCommandViaFallbackDirectoryOutsidePath() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-command-path-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let name = "cmux-gh-test-\(UUID().uuidString)"
        let executableURL = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runner = CommandRunner(
            environment: ["PATH": "/usr/bin:/bin"],
            bundledBinPath: nil,
            fallbackSearchDirectories: [dir.path]
        )
        #expect(runner.resolvedCommandPath(executable: name) == executableURL.path)
        #expect(runner.resolvedCommandPath(executable: "cmux-missing-\(UUID().uuidString)") == nil)
    }

    @Test func unresolvableCommandRunsViaEnvAndExitsNonZero() async {
        // A bare command that resolves nowhere falls back to `/usr/bin/env <cmd>`,
        // which exits non-zero (127) rather than failing to spawn. The stdout-only
        // convenience therefore yields nil, which is the contract callers rely on.
        let result = await runner.run(
            directory: tempDir,
            executable: "cmux-definitely-not-a-real-command",
            arguments: [],
            timeout: 10
        )
        #expect(result.executionError == nil)
        #expect(result.timedOut == false)
        #expect((result.exitStatus ?? 0) != 0)

        let output = await runner.runStandardOutput(
            directory: tempDir,
            executable: "cmux-definitely-not-a-real-command",
            arguments: [],
            timeout: 10
        )
        #expect(output == nil)
    }
}
