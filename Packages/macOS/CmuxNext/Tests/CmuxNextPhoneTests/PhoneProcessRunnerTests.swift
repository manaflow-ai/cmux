import Foundation
import Testing
@testable import CmuxNextPhone

/// The real runner, through `/usr/bin/xcrun` (which also finds plain tools on PATH).
@Suite struct PhoneProcessRunnerTests {
    @Test func aRunReturnsAllOfItsStdoutAndStatus() async throws {
        // 200 KB is more than one pipe buffer: the run must drain while it waits.
        let result = try await PhoneProcessRunner().run(["head", "-c", "200000", "/dev/zero"], stdin: nil, deadline: .seconds(20))
        #expect(result.status == 0)
        #expect(result.stdout.count == 200_000)
    }

    @Test func stdinIsWrittenAndStderrKept() async throws {
        let echo = try await PhoneProcessRunner().run(["cat"], stdin: Data("hello".utf8), deadline: .seconds(20))
        #expect(String(decoding: echo.stdout, as: UTF8.self) == "hello")
        let missing = try await PhoneProcessRunner().run(["ls", "/no/such/path"], stdin: nil, deadline: .seconds(20))
        #expect(missing.status != 0)
        #expect(missing.stderr.contains("No such file"))
    }

    /// A pasteboard far past one pipe buffer, to a child that reads only after a second: every byte
    /// arrives, and the caller is not the one waiting for the child to read (the feed's queue is).
    @Test(.timeLimit(.minutes(1))) func aLargeStdinReachesASlowReaderWhole() async throws {
        let result = try await PhoneProcessRunner().run(["sh", "-c", "sleep 1; wc -c"], stdin: Data(repeating: 0x61, count: 1_024 * 1_024),
                                                        deadline: .seconds(20))
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1048576")
    }

    @Test func aStartedCommandStopsOnInterruptAndOwnsItsStdoutFile() async throws {
        let file = temporaryFolder().appendingPathComponent("out.txt")
        let command = try await PhoneProcessRunner().start(["sleep", "60"], stdoutFile: file)
        await command.interrupt()
        let status = await command.waitForExit(deadline: .seconds(10))
        #expect(status != 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The child exits at once and leaves a process behind that holds its stdout open. The run ends
    /// at the child's exit with what the child wrote, not when the one left behind lets go of the pipe.
    @Test(.timeLimit(.minutes(1))) func aRunEndsAtTheExitWhenAProcessLeftBehindHoldsItsStdout() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        // The shell prints the pid of the `sleep` it leaves behind (which holds the shell's stdout), then exits.
        let result = try await PhoneProcessRunner().run(["sh", "-c", "sleep 60 & echo $!"], stdin: nil, deadline: .seconds(50))
        let leftover = pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        // The process left behind does not outlive the test.
        defer { if let leftover, leftover > 1 { kill(leftover, SIGKILL) } }
        #expect(result.status == 0)
        #expect(leftover != nil, "stdout was not the pid the shell printed before it exited")
        // Far below the 60 s the process left behind holds the pipe; a cold `xcrun` takes seconds.
        #expect(clock.now - start < .seconds(30))
    }

    @Test func theDeadlineKillsARunThatHangs() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await PhoneProcessRunner().run(["sleep", "60"], stdin: nil, deadline: .milliseconds(300))
        #expect(result.status != 0)
        #expect(clock.now - start < .seconds(20))
    }
}

/// A child that exits without reading its stdin closes the pipe's read end, so the write fails with
/// EPIPE. `FileHandle.write(_:)` raises that as an Objective-C exception (and SIGPIPE ends a process
/// that does not ignore it): a simulator that is not booted made `simctl pbcopy` do exactly this.
@Suite struct PhoneProcessBrokenStdinTests {
    @Test func aChildThatNeverReadsItsStdinEndsTheRunInsteadOfTheApp() async throws {
        // Larger than a pipe buffer, so the write is still going when `true` has already exited.
        let result = try await PhoneProcessRunner().run(["true"], stdin: Data(count: 4 << 20), deadline: .seconds(20))
        #expect(result.status == 0)
    }
}
