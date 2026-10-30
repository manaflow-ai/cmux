import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The person's restart signals only the process it found, known by its pid and start time: a pid the
/// kernel gave to another process (another start time) gets no signal. The "other process" is a
/// stand-in identity; the signalled process is a `sleep` this test starts.
///
/// No suite time limit: every wait here is bounded (the child's `exec`, the grace, the SIGKILL's
/// exit), and in the full parallel run on a loaded 6-vCPU runner a whole test process stalls for
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

        #expect(await stopper.stop(found, grace: .milliseconds(300)), "the daemon it found is gone")
        #expect(agentPaneProcessIsRunning(child.processIdentifier), "the process that has the pid now was signalled")
    }

    @Test func aPidReusedAfterItsSigtermGetsNoSigkill() async throws {
        let child = try await child(ignoresTerm: true)
        defer { kill(child.processIdentifier, SIGKILL) }
        let found = try #require(AcpmuxDaemonStop.kernelProcess(pid: child.processIdentifier))
        // The first read is the check before SIGTERM; every later one sees another process.
        let stopper = AcpmuxDaemonStop(process: reused(after: 1))

        #expect(await stopper.stop(found, grace: .milliseconds(300)))
        #expect(agentPaneProcessIsRunning(child.processIdentifier), "the process that has the pid now got SIGKILL")
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

    @Test func theProcessItFoundGetsSigtermThenSigkill() async throws {
        let child = try await child(ignoresTerm: true)
        defer { kill(child.processIdentifier, SIGKILL) }
        let found = try #require(AcpmuxDaemonStop.kernelProcess(pid: child.processIdentifier))
        let stopper = AcpmuxDaemonStop()

        #expect(await stopper.stop(found, grace: .milliseconds(300)))
        #expect(!agentPaneProcessIsRunning(child.processIdentifier))
    }
}

/// The waiting line's "Restart agent service" (lead decision on #28083): the app never restarts
/// a slow acpmux on its own, so a person can. It stops this app's own daemon once, only while a
/// pane waits for it, and the next handshake starts a new one.
@Suite(.serialized)
@MainActor
struct AcpmuxRestartStuckTests {
    private actor NoHost: AgentPaneHostProviding {
        private(set) var restarts = 0
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func restartStuckAcpmux() async -> Bool {
            restarts += 1
            return true
        }
    }

    /// Page script cannot stop the daemon: only a real click reaches the host.
    @Test func restartAgentServiceNeedsAGesture() async {
        let host = NoHost()
        let model = AgentPaneModel(host: host)
        let ungestured = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.restartStuck", "params": [:]]))
        #expect((ungestured["error"] as? [String: Any])?["code"] as? String == "acpmux.gesture_required")
        #expect(await host.restarts == 0)
        model.transport.gestures.record(click: true)
        let clicked = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.restartStuck", "params": [:]]))
        #expect((clicked["value"] as? [String: Any])?["stopped"] as? Bool == true, "\(clicked)")
        #expect(await host.restarts == 1)
    }

    /// A pane waits on this app's own daemon, which never answers. The person's restart stops it
    /// once (SIGTERM), the waiting handshake ends, and the next handshake starts one daemon. With
    /// no pane waiting, the action stops nothing.
    @Test func restartAgentServiceRestartsTheWaitedForDaemonOnce() async throws {
        let fixture = try AcpmuxSlowDaemonTests.OwnedFixture()
        let ended = AsyncStream<Int32>.makeStream()
        let silent = try await fixture.silentDaemon { signal in
            ended.continuation.yield(signal)
            ended.continuation.finish()
        }
        defer { fixture.remove(silent) }
        try fixture.writePidFile(silent.processIdentifier)
        let host = AcpmuxHost(environment: fixture.environment)

        #expect(await !host.restartStuckAcpmux(), "a daemon no pane waits for was stopped")
        #expect(agentPaneProcessIsRunning(silent.processIdentifier))

        // task-owner: the pane's handshake that waits on the silent daemon; awaited below
        let waiting = Task { try await host.reconnectHandshake(sessionId: nil) }
        // The lookup is in flight once the daemon took its connection; the restart needs one.
        let deadline = ContinuousClock.now + .seconds(60)
        var stopped = false
        while !stopped, ContinuousClock.now < deadline {
            stopped = await host.restartStuckAcpmux()
            if !stopped { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(stopped, "the person's restart did not stop the daemon a pane waits for")
        var signal: Int32?
        for await value in ended.stream { signal = value }
        #expect(signal == SIGTERM)
        await #expect(throws: (any Error).self) { _ = try await waiting.value }

        _ = try? await host.handshake(sessionId: nil)
        #expect(fixture.launches == 1, "acpmux was started \(fixture.launches) times after one restart")
        #expect(fixture.log.contains(AcpmuxFailureCause.personRestart.logText))
    }
}
