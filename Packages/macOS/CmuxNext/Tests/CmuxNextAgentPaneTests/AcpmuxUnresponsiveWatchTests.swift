import CmuxNextCompat
import Darwin
import Foundation
import CmuxNextWakeupsTestSupport
import Testing
@testable import CmuxNextAgentPane

/// The watch's timing: misses in a row, spanning the window, with no answer between them.
struct AcpmuxUnresponsiveWatchTests {
    let clock = ManualClock()

    func watch() -> AcpmuxUnresponsiveWatch {
        AcpmuxUnresponsiveWatch(clock: clock, misses: 3, window: .seconds(20), streakGap: .seconds(300))
    }

    @Test func restartsAfterThreeMissesSpanningTheWindow() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(5))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(5))
        #expect(!watch.missed(home: "/h", pid: 7), "three misses in 10 s are not 20 s")
        clock.advance(by: .seconds(11))
        #expect(watch.missed(home: "/h", pid: 7))
    }

    /// A daemon that wedges again after every start is left for a person after `perLaunch`.
    @Test func eachHomeRestartsAtMostPerLaunchTimes() throws {
        let watch = AcpmuxUnresponsiveWatch(clock: clock, misses: 1, window: .zero, perLaunch: 2)
        let first = try #require(watch.miss(home: "/h", pid: 7))
        #expect(watch.claim(home: "/h", streak: first, pid: 7))
        #expect(!watch.claim(home: "/h", streak: first, pid: 7), "one restart per streak")
        #expect(!watch.missed(home: "/h", pid: 7), "one restart per pid")
        let second = try #require(watch.miss(home: "/h", pid: 8))
        #expect(watch.claim(home: "/h", streak: second, pid: 8))
        #expect(!watch.missed(home: "/h", pid: 9), "two restarts of /h in this launch")
        #expect(watch.missed(home: "/other", pid: 9), "another home has its own")
    }

    @Test func anAnswerEndsTheStreak() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(10))
        #expect(!watch.missed(home: "/h", pid: 7))
        watch.answered(home: "/h")
        clock.advance(by: .seconds(11))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(10))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(10))
        #expect(watch.missed(home: "/h", pid: 7))
    }

    /// Review of #25379: while one lookup waits on its confirming status call, another lookup's
    /// call is answered. The streak that made the restart due is gone, so the claim says no and
    /// the daemon, which answers again, is kept.
    @Test func aDaemonThatAnsweredMeanwhileIsNotClaimed() throws {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(10))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(11))
        let due = try #require(watch.miss(home: "/h", pid: 7))
        // While that lookup confirms: another lookup is answered, then three more miss, within
        // a few seconds (a new streak, its window not passed).
        watch.answered(home: "/h")
        #expect(!watch.claim(home: "/h", streak: due, pid: 7), "a daemon that answered again was claimed for a restart")
        for _ in 0..<3 {
            clock.advance(by: .seconds(1))
            #expect(!watch.missed(home: "/h", pid: 7))
        }
        #expect(!watch.claim(home: "/h", streak: due, pid: 7), "the old confirm claimed the new streak before its window")
        // The new streak was left as it was: once its window passed, it restarts the daemon.
        clock.advance(by: .seconds(18))
        let next = try #require(watch.miss(home: "/h", pid: 7))
        #expect(watch.claim(home: "/h", streak: next, pid: 7))
    }

    @Test func anotherPidOrAnotherHomeHasItsOwnStreak() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(10))
        #expect(!watch.missed(home: "/other", pid: 9))
        #expect(!watch.missed(home: "/h", pid: 8))
        clock.advance(by: .seconds(15))
        #expect(!watch.missed(home: "/h", pid: 8))
        clock.advance(by: .seconds(10))
        #expect(watch.missed(home: "/h", pid: 8))
    }

    @Test func aMissLongAfterTheLastStartsANewStreak() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(10))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(by: .seconds(400))
        #expect(!watch.missed(home: "/h", pid: 7))
    }
}

/// The watch signals only the process it found, known by its pid and start time: a pid the
/// kernel gave to another process (another start time) gets no signal. The "other process" is a
/// stand-in identity; the signalled process is a `sleep` this test starts.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AcpmuxUnresponsiveIdentityTests {
    /// A `sleep` child; with `ignoresTerm` it ignores SIGTERM (the disposition survives `exec`).
    private func child(ignoresTerm: Bool) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", (ignoresTerm ? "trap '' TERM; " : "") + "exec /bin/sleep 60"]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Signalled before its `exec`, bash would still take SIGTERM.
        let deadline = ContinuousClock.now + .seconds(5)
        while AcpmuxVersionHandoff.executablePath(pid: process.processIdentifier) != "/bin/sleep", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return process
    }

    /// Identity reads so far, shared with the stand-in.
    private nonisolated final class Reads: Sendable {
        let count = Mutex(0)
    }

    /// The real identity of `pid` for the first `real` reads, then another process's.
    private func reused(after real: Int) -> @Sendable (Int32) -> AcpmuxUnresponsiveWatch.Daemon? {
        let reads = Reads()
        return { pid in
            guard var daemon = AcpmuxUnresponsiveWatch.kernelProcess(pid: pid) else { return nil }
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
        let found = try #require(AcpmuxUnresponsiveWatch.kernelProcess(pid: child.processIdentifier))
        let watch = AcpmuxUnresponsiveWatch(clock: ManualClock(), process: reused(after: 0))

        #expect(await watch.stop(found, grace: .milliseconds(300)), "the daemon it found is gone")
        #expect(agentPaneProcessIsRunning(child.processIdentifier), "the process that has the pid now was signalled")
    }

    @Test func aPidReusedAfterItsSigtermGetsNoSigkill() async throws {
        let child = try await child(ignoresTerm: true)
        defer { kill(child.processIdentifier, SIGKILL) }
        let found = try #require(AcpmuxUnresponsiveWatch.kernelProcess(pid: child.processIdentifier))
        // The first read is the check before SIGTERM; every later one sees another process.
        let watch = AcpmuxUnresponsiveWatch(clock: ManualClock(), process: reused(after: 1))

        #expect(await watch.stop(found, grace: .milliseconds(300)))
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
        let found = try #require(AcpmuxUnresponsiveWatch.kernelProcess(pid: pid))

        let answer = AcpmuxUnresponsiveWatch.signal(found, SIGTERM) { _ in
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
        var earlier = try #require(AcpmuxUnresponsiveWatch.kernelProcess(pid: child.processIdentifier))
        #expect(earlier.token.val.5 == UInt32(bitPattern: child.processIdentifier))
        earlier.token.val.7 &+= 1

        let answer = AcpmuxUnresponsiveWatch.signal(earlier, SIGTERM) { _ in earlier }
        #expect(answer == true, "the kernel refuses it (ESRCH): the process of that token is gone")
        #expect(agentPaneProcessIsRunning(child.processIdentifier), "the process that has the pid now was signalled")
    }

    @Test func theProcessItFoundGetsSigtermThenSigkill() async throws {
        let child = try await child(ignoresTerm: true)
        defer { kill(child.processIdentifier, SIGKILL) }
        let found = try #require(AcpmuxUnresponsiveWatch.kernelProcess(pid: child.processIdentifier))
        let watch = AcpmuxUnresponsiveWatch(clock: ManualClock())

        #expect(await watch.stop(found, grace: .milliseconds(300)))
        #expect(!agentPaneProcessIsRunning(child.processIdentifier))
    }
}

/// A local acpmux that is alive but never answers: its socket takes connections and reads
/// them. After three missed status calls spanning 20 s (one more with the longer deadline),
/// the app stops it and starts a daemon. The hung daemon is `nc` copied (and signed ad hoc) to a
/// file named `acpmux`, listening on the temp home's socket; the started daemon is a stand-in that only
/// records its launch. Never this app's acpmux.
@Suite(.serialized, .timeLimit(.minutes(2)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/nc"), "needs /usr/bin/nc"))
struct AcpmuxUnresponsiveRestartTests {
    struct Fixture {
        let root: URL
        let environment: AcpmuxEnvironment
        var launched: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path) }
        var log: String { (try? String(contentsOfFile: environment.logPath, encoding: .utf8)) ?? "" }

        init() throws {
            root = URL(fileURLWithPath: "/tmp/aur-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let acpmux = bin.appendingPathComponent("acpmux")
            try "#!/bin/sh\ntouch '\(root.path)/launched'\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
            environment = try #require(AcpmuxEnvironment.resolve(
                build: nil, bundledBinDirectory: bin,
                environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path],
                executableOverride: nil))
            // The failure log appends to an existing daemon.log only.
            FileManager.default.createFile(atPath: environment.logPath, contents: nil)
        }

        /// Starts a hung `acpmux` listening on `socketPath`; with `ignoresTerm` it ignores SIGTERM.
        func hungDaemon(socketPath: String, ignoresTerm: Bool = false, name: String = "hung") async throws -> HungDaemon {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("acpmux")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/nc"), to: executable)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // macOS 27 kills a copied system binary at exec; signed ad hoc, the copy runs.
            process.arguments = ["-c", (ignoresTerm ? "trap '' TERM; " : "") + #"/usr/bin/codesign -f -s - "$0" 2>/dev/null; exec "$0" -dklU "$1""#,
                                 executable.path, socketPath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let ended = HungDaemon.Ended()
            process.terminationHandler = { process in
                let signal = process.terminationReason == .uncaughtSignal ? process.terminationStatus : 0
                ended.signal.withLock { $0 = signal }
            }
            try process.run()
            let hung = HungDaemon(process, ended: ended)
            let deadline = ContinuousClock.now + .seconds(5)
            while AcpmuxUnresponsiveWatch.listenerPID(socketPath: socketPath) != process.processIdentifier,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(AcpmuxUnresponsiveWatch.listenerPID(socketPath: socketPath) == process.processIdentifier)
            return hung
        }

        func writePidFile(_ pid: Int32) throws {
            try "\(pid)\n".write(to: environment.home.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)
        }

        func remove(_ daemons: [HungDaemon]) {
            for daemon in daemons { kill(daemon.pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Three handshakes 11 s apart on the watch's clock; each status call misses its 2 s deadline.
    private func missThreeTimes(_ host: AcpmuxHost, clock: ManualClock, stillAlive: Int32) async {
        for _ in 0..<2 {
            await #expect(throws: AgentPaneHostError.timedOut) { try await host.prewarm() }
            #expect(agentPaneProcessIsRunning(stillAlive))
            clock.advance(by: .seconds(11))
        }
        await #expect(throws: (any Error).self) { try await host.prewarm() }
    }

    private func host(_ fixture: Fixture, clock: ManualClock, enabled: Bool = true) -> AcpmuxHost {
        host(fixture, clock: clock, toggle: { enabled })
    }

    private func host(_ fixture: Fixture, clock: ManualClock, toggle: @escaping @Sendable () -> Bool) -> AcpmuxHost {
        let watch = AcpmuxUnresponsiveWatch(clock: clock, confirm: .milliseconds(300), termGrace: .seconds(2))
        return AcpmuxHost(environment: fixture.environment, unresponsive: watch, restartsUnresponsive: toggle)
    }

    /// The toggle's reads, and what it answers.
    private nonisolated final class Toggle: Sendable {
        private let state = Mutex((reads: 0, on: true))
        /// Off from read `offFrom` on (1-based); nil: `on` decides.
        let offFrom: Int?
        init(offFrom: Int? = nil) { self.offFrom = offFrom }
        var on: Bool {
            get { state.withLock { $0.on } }
            set { state.withLock { $0.on = newValue } }
        }
        func read() -> Bool {
            state.withLock { state in
                state.reads += 1
                if let offFrom { return state.reads < offFrom }
                return state.on
            }
        }
    }

    @Test func aHungDaemonGetsSigtermAndANewDaemonStarts() async throws {
        let fixture = try Fixture()
        let hung = try await fixture.hungDaemon(socketPath: fixture.environment.socketPath)
        defer { fixture.remove([hung]) }
        try fixture.writePidFile(hung.pid)
        let clock = ManualClock()

        await missThreeTimes(host(fixture, clock: clock), clock: clock, stillAlive: hung.pid)
        #expect(!agentPaneProcessIsRunning(hung.pid), "the hung daemon still runs")
        #expect(await hung.signal() == SIGTERM)
        #expect(fixture.launched, "no new daemon was started after the hung one stopped")
        #expect(fixture.log.contains(AcpmuxFailureCause.unresponsive.logText))
    }

    @Test func oneThatIgnoresSigtermGetsSigkill() async throws {
        let fixture = try Fixture()
        let hung = try await fixture.hungDaemon(socketPath: fixture.environment.socketPath, ignoresTerm: true)
        defer { fixture.remove([hung]) }
        try fixture.writePidFile(hung.pid)
        let clock = ManualClock()

        await missThreeTimes(host(fixture, clock: clock), clock: clock, stillAlive: hung.pid)
        #expect(!agentPaneProcessIsRunning(hung.pid))
        #expect(await hung.signal() == SIGKILL)
        #expect(fixture.launched)
    }

    /// `daemon.pid` names an acpmux that does not listen on this home's socket (another home's
    /// daemon): it is never signalled, nor is the process that does listen.
    @Test func aPidThatDoesNotHoldThisHomesSocketIsNeverSignalled() async throws {
        let fixture = try Fixture()
        let hung = try await fixture.hungDaemon(socketPath: fixture.environment.socketPath)
        let otherSocket = fixture.root.appendingPathComponent("other.sock").path
        let other = try await fixture.hungDaemon(socketPath: otherSocket, name: "other")
        defer { fixture.remove([hung, other]) }
        try fixture.writePidFile(other.pid)
        let clock = ManualClock()

        await missThreeTimes(host(fixture, clock: clock), clock: clock, stillAlive: hung.pid)
        #expect(agentPaneProcessIsRunning(hung.pid))
        #expect(agentPaneProcessIsRunning(other.pid))
        #expect(!fixture.launched)
    }

    @Test func theToggleOffKeepsTheDaemon() async throws {
        let fixture = try Fixture()
        let hung = try await fixture.hungDaemon(socketPath: fixture.environment.socketPath)
        defer { fixture.remove([hung]) }
        try fixture.writePidFile(hung.pid)
        let clock = ManualClock()

        await missThreeTimes(host(fixture, clock: clock, enabled: false), clock: clock, stillAlive: hung.pid)
        #expect(agentPaneProcessIsRunning(hung.pid))
        #expect(!fixture.launched)
    }

    /// Review of #25379: the toggle turned off while the third lookup waits on its status calls.
    /// It is on for each lookup's start and off by the restart's claim, so the daemon is kept.
    @Test func theToggleTurnedOffBeforeTheClaimKeepsTheDaemon() async throws {
        let fixture = try Fixture()
        let hung = try await fixture.hungDaemon(socketPath: fixture.environment.socketPath)
        defer { fixture.remove([hung]) }
        try fixture.writePidFile(hung.pid)
        let clock = ManualClock()
        // Reads 1-3: the three lookups; read 4 on: the toggle is off.
        let toggle = Toggle(offFrom: 4)

        await missThreeTimes(host(fixture, clock: clock, toggle: { toggle.read() }), clock: clock, stillAlive: hung.pid)
        #expect(agentPaneProcessIsRunning(hung.pid), "the daemon was restarted with the toggle off")
        #expect(!fixture.launched)
    }

    /// Review of #25379: a lookup with the toggle off ends the streak, so misses from before it
    /// never add up to a restart with misses after it.
    @Test func aLookupWithTheToggleOffEndsTheStreak() async throws {
        let fixture = try Fixture()
        let hung = try await fixture.hungDaemon(socketPath: fixture.environment.socketPath)
        defer { fixture.remove([hung]) }
        try fixture.writePidFile(hung.pid)
        let clock = ManualClock()
        let toggle = Toggle()
        let host = host(fixture, clock: clock, toggle: { toggle.read() })

        for on in [true, true, false, true] {
            toggle.on = on
            await #expect(throws: AgentPaneHostError.timedOut) { try await host.prewarm() }
            clock.advance(by: .seconds(11))
        }
        #expect(agentPaneProcessIsRunning(hung.pid), "misses on both sides of a lookup with the toggle off restarted the daemon")
        #expect(!fixture.launched)
    }
}

/// A hung daemon process and the signal that ended it (from its termination handler, which runs
/// once Foundation reaped it).
nonisolated final class HungDaemon: @unchecked Sendable {  // `process` is only read for its pid, set once at its launch
    nonisolated final class Ended: Sendable {
        let signal = Mutex<Int32?>(nil)
    }

    private let process: Process
    let ended: Ended
    var pid: Int32 { process.processIdentifier }

    init(_ process: Process, ended: Ended) {
        self.process = process
        self.ended = ended
    }

    /// The signal that ended it (0: it exited); nil when it has not ended within 5 s.
    func signal() async -> Int32? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ended.signal.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ended.signal.withLock { $0 }
    }
}
