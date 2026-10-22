import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A clock that moves only when the test advances it. Nothing sleeps on it: the watch only
/// reads `now`.
nonisolated final class AcpmuxWatchClock: Clock, Sendable {
    nonisolated struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    typealias Duration = Swift.Duration
    private let current = Mutex(Instant(offset: .zero))
    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Swift.Duration { .zero }

    func advance(_ duration: Swift.Duration) { current.withLock { $0 = $0.advanced(by: duration) } }

    @concurrent func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()
    }
}

/// The watch's timing: misses in a row, spanning the window, with no answer between them.
struct AcpmuxUnresponsiveWatchTests {
    let clock = AcpmuxWatchClock()

    func watch() -> AcpmuxUnresponsiveWatch {
        AcpmuxUnresponsiveWatch(clock: clock, misses: 3, window: .seconds(20), streakGap: .seconds(300))
    }

    @Test func restartsAfterThreeMissesSpanningTheWindow() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(5))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(5))
        #expect(!watch.missed(home: "/h", pid: 7), "three misses in 10 s are not 20 s")
        clock.advance(.seconds(11))
        #expect(watch.missed(home: "/h", pid: 7))
    }

    /// A daemon that wedges again after every start is left for a person after `perLaunch`.
    @Test func eachHomeRestartsAtMostPerLaunchTimes() {
        let watch = AcpmuxUnresponsiveWatch(clock: clock, misses: 1, window: .zero, perLaunch: 2)
        #expect(watch.missed(home: "/h", pid: 7))
        #expect(watch.claim(home: "/h", pid: 7))
        #expect(!watch.claim(home: "/h", pid: 7), "one restart per pid")
        #expect(watch.missed(home: "/h", pid: 8))
        #expect(watch.claim(home: "/h", pid: 8))
        #expect(!watch.missed(home: "/h", pid: 9), "two restarts of /h in this launch")
        #expect(!watch.claim(home: "/h", pid: 9))
        #expect(watch.missed(home: "/other", pid: 9), "another home has its own")
    }

    @Test func anAnswerEndsTheStreak() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(10))
        #expect(!watch.missed(home: "/h", pid: 7))
        watch.answered(home: "/h")
        clock.advance(.seconds(11))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(10))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(10))
        #expect(watch.missed(home: "/h", pid: 7))
    }

    @Test func anotherPidOrAnotherHomeHasItsOwnStreak() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(10))
        #expect(!watch.missed(home: "/other", pid: 9))
        #expect(!watch.missed(home: "/h", pid: 8))
        clock.advance(.seconds(15))
        #expect(!watch.missed(home: "/h", pid: 8))
        clock.advance(.seconds(10))
        #expect(watch.missed(home: "/h", pid: 8))
    }

    @Test func aMissLongAfterTheLastStartsANewStreak() {
        let watch = watch()
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(10))
        #expect(!watch.missed(home: "/h", pid: 7))
        clock.advance(.seconds(400))
        #expect(!watch.missed(home: "/h", pid: 7))
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
    private func missThreeTimes(_ host: AcpmuxHost, clock: AcpmuxWatchClock, stillAlive: Int32) async {
        for _ in 0..<2 {
            await #expect(throws: AgentPaneHostError.timedOut) { try await host.prewarm() }
            #expect(agentPaneProcessIsRunning(stillAlive))
            clock.advance(.seconds(11))
        }
        await #expect(throws: (any Error).self) { try await host.prewarm() }
    }

    private func host(_ fixture: Fixture, clock: AcpmuxWatchClock, enabled: Bool = true) -> AcpmuxHost {
        let watch = AcpmuxUnresponsiveWatch(clock: clock, confirm: .milliseconds(300), termGrace: .seconds(2))
        return AcpmuxHost(environment: fixture.environment, unresponsive: watch,
                          restartsUnresponsive: { enabled }, handsOffWhenQuiet: { false })
    }

    @Test func aHungDaemonGetsSigtermAndANewDaemonStarts() async throws {
        let fixture = try Fixture()
        let hung = try await fixture.hungDaemon(socketPath: fixture.environment.socketPath)
        defer { fixture.remove([hung]) }
        try fixture.writePidFile(hung.pid)
        let clock = AcpmuxWatchClock()

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
        let clock = AcpmuxWatchClock()

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
        let clock = AcpmuxWatchClock()

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
        let clock = AcpmuxWatchClock()

        await missThreeTimes(host(fixture, clock: clock, enabled: false), clock: clock, stillAlive: hung.pid)
        #expect(agentPaneProcessIsRunning(hung.pid))
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
