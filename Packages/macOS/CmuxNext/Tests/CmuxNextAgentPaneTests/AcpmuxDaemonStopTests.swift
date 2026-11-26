import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The person's restart signals only the process it found, known by its pid and start time: a pid the
/// kernel gave to another process (another start time) gets no signal. The "other process" is a
/// stand-in identity; the signalled process is a `sleep` this test starts.
///
/// No suite time limit: every wait here is bounded (the child's `exec`, its exit), and in the full parallel run on a loaded 6-vCPU runner a whole test process stalls for
/// a minute or more (job 122473154125: a suite that only advanced a manual clock took 170 s), so a
/// one-minute limit failed tests that checked nothing about time.
@Suite(.serialized)
struct AcpmuxDaemonStopIdentityTests {
    /// A `sleep` child; with `ignoresTerm` it ignores SIGTERM (the disposition survives `exec`).
    /// It outlives any stall of this test (the test kills it), so "still running" means it was
    /// not signalled, never that it has not exited yet.
    private func child(ignoresTerm: Bool) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", (ignoresTerm ? "trap '' TERM; " : "") + "exec /bin/sleep 3600"]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // The caller's cleanup starts once this returns; until then a failed start kills it here.
        var started = false
        defer { if !started { kill(process.processIdentifier, SIGKILL) } }
        // Signalled before its `exec`, bash would still take SIGTERM. A load-tolerant deadline:
        // the test checks the signals, not how fast a child starts.
        let deadline = ContinuousClock.now + .seconds(60)
        while AcpmuxVersionHandoff.executablePath(pid: process.processIdentifier) != "/bin/sleep",
              process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(AcpmuxVersionHandoff.executablePath(pid: process.processIdentifier) == "/bin/sleep")
        started = true
        return process
    }

    /// Identity reads so far, shared with the stand-in.
    private nonisolated final class Reads: Sendable {
        let count = Mutex(0)
    }

    /// The real identity of `pid` for the first `real` reads, then another process's.
    private func reused(after real: Int) -> @Sendable (Int32) -> AcpmuxDaemonStop.Daemon? {
        let reads = Reads()
        return { pid in
            guard var daemon = AcpmuxDaemonStop.kernelProcess(pid: pid) else { return nil }
            let read = reads.count.withLock { count in
                defer { count += 1 }
                return count
            }
            if read >= real { daemon.startMicroseconds &+= 1 }
            return daemon
        }
    }

    @Test func aPidThatNamesAnotherProcessNowGetsNoSignal() async throws {
        let child = try await child(ignoresTerm: false)
        defer { kill(child.processIdentifier, SIGKILL) }
        let found = try #require(AcpmuxDaemonStop.kernelProcess(pid: child.processIdentifier))
        let stopper = AcpmuxDaemonStop(process: reused(after: 0))

        #expect(!stopper.terminate(found), "a signal went to a pid that names another process now")
        #expect(agentPaneProcessIsRunning(child.processIdentifier), "the process that has the pid now was signalled")
    }

    /// Review of #23199: the check and the signal were apart, so a daemon that exited between
    /// them got the signal sent to its pid. The process here is this test's own unreaped child
    /// (`posix_spawn`, so nothing reaps it), so `kill` alone would still report it signalled.
    @Test func aDaemonThatExitsAfterItsCheckGetsNoSignal() throws {
        var pid: pid_t = 0
        let words: [String] = ["/bin/sleep", "60"]
        var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, environ) == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        let found = try #require(AcpmuxDaemonStop.kernelProcess(pid: pid))

        let answer = AcpmuxDaemonStop.signal(found, SIGTERM) { _ in
            // The check passes, then the daemon exits (a zombie until the defer reaps it).
            kill(pid, SIGKILL)
            var info = siginfo_t()
            waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            return found
        }
        #expect(answer == true, "an exit after the check is seen and nothing is sent")
    }

    /// Review of #23199: after the last look the thread can stop for any time (a debugger), and
    /// the pid can name another process when it resumes. The token here is the child's with
    /// another pid version, as a later process with that pid would have; the identity stand-in
    /// still passes it, so only the kernel's token check is left.
    @Test func aSignalForAnotherProcessWithThePidIsRefused() async throws {
        let child = try await child(ignoresTerm: false)
        defer { kill(child.processIdentifier, SIGKILL) }
        var earlier = try #require(AcpmuxDaemonStop.kernelProcess(pid: child.processIdentifier))
        #expect(earlier.token.val.5 == UInt32(bitPattern: child.processIdentifier))
        earlier.token.val.7 &+= 1

        let answer = AcpmuxDaemonStop.signal(earlier, SIGTERM) { _ in earlier }
        #expect(answer == true, "the kernel refuses it (ESRCH): the process of that token is gone")
        #expect(agentPaneProcessIsRunning(child.processIdentifier), "the process that has the pid now was signalled")
    }

    /// The process it found gets SIGTERM and ends its own way.
    @Test func theProcessItFoundGetsSigterm() async throws {
        let child = try await child(ignoresTerm: false)
        defer { kill(child.processIdentifier, SIGKILL) }
        let found = try #require(AcpmuxDaemonStop.kernelProcess(pid: child.processIdentifier))
        let exit = AgentPaneProcessExit(pid: child.processIdentifier)

        #expect(AcpmuxDaemonStop().terminate(found))
        #expect(await exit.event(within: nil), "the daemon did not exit at SIGTERM")
    }

    /// A daemon that does not end at SIGTERM is never killed: a SIGKILL during an event-log write
    /// could tear a session record (acpmux store.rs `append`). It keeps running, and the person may
    /// press again.
    @Test func aDaemonThatIgnoresSigtermIsNeverKilled() async throws {
        let child = try await child(ignoresTerm: true)
        defer { kill(child.processIdentifier, SIGKILL) }
        let found = try #require(AcpmuxDaemonStop.kernelProcess(pid: child.processIdentifier))
        let stopper = AcpmuxDaemonStop()

        #expect(stopper.terminate(found))
        #expect(stopper.terminate(found), "a second press did not signal again")
        #expect(agentPaneProcessIsRunning(child.processIdentifier))
    }
}
