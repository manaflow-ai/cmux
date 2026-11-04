import Darwin
import Foundation
import CmuxNextWakeupsTestSupport
import Testing
@testable import CmuxNextAgentPane

/// Settings > Updates' acpmux daemon line (the Channels card): the running build, and whether it
/// is the bundled build, restarting on it, another build the app keeps, or not running.
@Suite struct AcpmuxDaemonSummaryTests {
    typealias Summary = AcpmuxDaemonSummary

    /// A home and socket of its own per test, so no test's handoff mark reaches another.
    private static func environment() -> AcpmuxEnvironment {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ads-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                 socketPath: home.appendingPathComponent("acpmux.sock").path,
                                 daemonArguments: [], childEnvironment: [:])
    }

    /// A daemon that answers from this test process's pid (its executable exists: not replaced).
    private static func status(build: String, agentHosts: Bool, store: String = "local") -> AcpmuxStatus {
        AcpmuxStatus(["build": build, "pid": NSNumber(value: getpid()), "agentHosts": agentHosts, "store": ["mode": store]])
    }

    @Test func theBundledBuildIsUpToDate() {
        let summary = Summary(answered: true, running: "abc", bundled: "abc", restarting: false)
        #expect(summary == Summary(build: "abc", state: .upToDate))
        #expect(summary.text.contains("abc"))
        #expect(summary.text != "abc")
    }

    @Test func anotherBuildOrAHandoffIsRestarting() {
        let stale = Summary(answered: true, running: "old", bundled: "new", restarting: false)
        #expect(stale == Summary(build: "old", state: .restarting))
        #expect(stale.text.contains("old"))
        // Stopped by a handoff, the bundled daemon not up yet: its build is the bundled one.
        #expect(Summary(answered: false, running: nil, bundled: "new", restarting: true)
            == Summary(build: "new", state: .restarting))
    }

    /// A replaced bundle's daemon of the bundled build is restarted at the next lookup too.
    @Test func aReplacedBundleIsRestarting() {
        #expect(Summary(answered: true, running: "abc", bundled: "abc", restarting: false, replaced: true)
            == Summary(build: "abc", state: .restarting))
    }

    /// Another build no lookup hands off (a memory store without agent hosts, an attached daemon,
    /// a handoff that could not stop it) never says it restarts.
    @Test func anotherBuildNoLookupHandsOffIsNotTheAppsBuild() {
        let kept = Summary(answered: true, running: "old", bundled: "new", restarting: false, handsOff: false)
        #expect(kept == Summary(build: "old", state: .otherBuild))
        #expect(kept.text.contains("old"))
        #expect(Summary(answered: true, running: "abc", bundled: "abc", restarting: false, handsOff: false).state == .upToDate)
    }

    @Test func noAnswerIsNotRunning() {
        let summary = Summary(answered: false, running: nil, bundled: "new", restarting: false)
        #expect(summary == Summary(build: nil, state: .notRunning))
        #expect(!summary.text.isEmpty)
    }

    @Test func aBuildEitherSideDoesNotKnowIsUpToDate() {
        #expect(Summary(answered: true, running: "abc", bundled: nil, restarting: false) == Summary(build: "abc", state: .upToDate))
        #expect(Summary(answered: true, running: nil, bundled: "abc", restarting: false).state == .upToDate)
    }

    /// What a lookup would do, as the line reads it: a stale daemon that keeps its agents or its
    /// chats is handed off; a memory store without agent hosts and an attached daemon are not,
    /// and neither is a socket this launch already handed off once.
    @Test func theLineReadsWhatALookupWouldDo() {
        let environment = Self.environment()
        let stale = AcpmuxVersionHandoff.handsOff(Self.status(build: "old", agentHosts: true), environment: environment, bundled: "new")
        #expect(stale.handsOff)
        #expect(!stale.replaced)
        #expect(AcpmuxVersionHandoff.handsOff(Self.status(build: "old", agentHosts: false), environment: environment, bundled: "new").handsOff)
        #expect(!AcpmuxVersionHandoff.handsOff(Self.status(build: "old", agentHosts: false, store: "memory"),
                                               environment: environment, bundled: "new").handsOff)
        #expect(!AcpmuxVersionHandoff.handsOff(Self.status(build: "new", agentHosts: true), environment: environment, bundled: "new").handsOff)
        var attached = environment
        attached.isAttached = true
        #expect(!AcpmuxVersionHandoff.handsOff(Self.status(build: "old", agentHosts: true), environment: attached, bundled: "new").handsOff)
    }

    /// No acpmux, or nothing on the socket, is not running; a handoff's mark says restarting
    /// until it settles. One `--version` and one status call each, no daemon started.
    @Test func theLineIsReadOnceFromTheSocketAndTheHandoffMark() async {
        let daemons = AcpmuxLocalDaemons()
        #expect(await Summary.current(nil, daemons: daemons) == Summary(build: nil, state: .notRunning))
        let environment = Self.environment()
        #expect(await Summary.current(environment, daemons: daemons).state == .notRunning)
        daemons.mark(home: environment.home, restarting: true)
        #expect(await Summary.current(environment, daemons: daemons).state == .restarting)
        daemons.mark(home: environment.home, restarting: false)
        #expect(await Summary.current(environment, daemons: daemons).state == .notRunning)
    }

    /// A bundled acpmux that never answers `--version` does not hold the card: the probe's bound
    /// ends it on its clock (a manual one here), the stalled child gets SIGTERM, and the line comes
    /// back. Nothing measures wall time: a loaded runner stretched the old `< 10 s` wall-clock
    /// check to 11.8 s and 65 s (jobs 122236716988 and 122240111475).
    @Test func aStalledVersionProbeIsBounded() async throws {
        let stall = try StalledAcpmux()
        defer { stall.remove() }
        let environment = AcpmuxEnvironment(executable: stall.executable, home: stall.directory,
                                            socketPath: stall.directory.appendingPathComponent("acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        let clock = ManualClock()
        let line = Task { await Summary.current(environment, daemons: AcpmuxLocalDaemons(), versionClock: clock) }
        // The child runs and the bound is armed: only the clock ends the probe now.
        await stall.waitUntilStarted()
        try await clock.waitForSleeper(within: .seconds(60))
        clock.advance(by: Summary.versionBound)
        #expect(await line.value == Summary(build: nil, state: .notRunning))
        #expect(await stall.waitUntilStopped(), "the stalled --version was not stopped at its bound")
    }

    /// A stray daemon (another executable than the app's) is classed like a replaced bundle:
    /// restarting when a lookup takes it over, else not the app's build, whatever its build.
    @Test func aStrayDaemonIsRestartingOrNotTheAppsBuild() {
        #expect(Summary(answered: true, running: "abc", bundled: "abc", restarting: false, replaced: true, handsOff: true)
            == Summary(build: "abc", state: .restarting))
        #expect(Summary(answered: true, running: "abc", bundled: "abc", restarting: false, replaced: true, handsOff: false)
            == Summary(build: "abc", state: .otherBuild))
        // Nothing on the socket is never stray.
        #expect(AcpmuxStrayDaemon.takesOver(Self.status(build: "abc", agentHosts: true), environment: Self.environment())
            == (stray: false, takesOver: false))
    }
}

/// A bundled `acpmux` whose `--version` never answers: it marks its start, then waits on a long
/// `sleep`. SIGTERM ends it and marks that; a `sleep` that ran out marks that instead, so a test
/// tells a probe its bound stopped from one that waited the child out.
nonisolated struct StalledAcpmux {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("acpmux") }
    private var started: URL { directory.appendingPathComponent("started") }
    private var stopped: URL { directory.appendingPathComponent("stopped") }
    private var ranOut: URL { directory.appendingPathComponent("ran-out") }

    init() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ads-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            trap 'touch "\(stopped.path)"; kill "$child" 2>/dev/null; exit 143' TERM
            /bin/sleep 120 &
            child=$!
            touch "\(started.path)"
            wait "$child"
            touch "\(ranOut.path)"
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Returns once the child runs with its SIGTERM trap set.
    func waitUntilStarted() async {
        let started = started.path
        #expect(await Self.wait { FileManager.default.fileExists(atPath: started) }, "the stalled acpmux never started")
    }

    /// True once SIGTERM ended the child before its `sleep` ran out.
    func waitUntilStopped() async -> Bool {
        let stopped = stopped.path
        let ranOut = ranOut.path
        return await Self.wait { FileManager.default.fileExists(atPath: stopped) || FileManager.default.fileExists(atPath: ranOut) }
            && !FileManager.default.fileExists(atPath: ranOut)
    }

    /// Polls `condition`; the 60 s limit only fails a run that never gets there (nothing here is timed).
    private static func wait(_ condition: () -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
