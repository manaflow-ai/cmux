import Darwin
import Foundation
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
        #expect(await Summary.current(nil) == Summary(build: nil, state: .notRunning))
        let environment = Self.environment()
        #expect(await Summary.current(environment).state == .notRunning)
        Summary.mark(home: environment.home, restarting: true)
        #expect(await Summary.current(environment).state == .restarting)
        Summary.mark(home: environment.home, restarting: false)
        #expect(await Summary.current(environment).state == .notRunning)
    }

    /// A bundled acpmux that never answers `--version` does not hold the card: the line comes
    /// back within the version bound plus the status deadline.
    @Test func aStalledVersionProbeIsBounded() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ads-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stall = directory.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: stall, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stall.path)
        let environment = AcpmuxEnvironment(executable: stall, home: directory,
                                            socketPath: directory.appendingPathComponent("acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        let clock = ContinuousClock()
        let started = clock.now
        let summary = await Summary.current(environment)
        #expect(clock.now - started < .seconds(10))
        #expect(summary == Summary(build: nil, state: .notRunning))
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
