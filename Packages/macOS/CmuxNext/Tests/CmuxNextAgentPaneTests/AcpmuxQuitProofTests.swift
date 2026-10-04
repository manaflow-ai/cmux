@testable import CmuxNextAgentPane
import Darwin
import Foundation
import Testing

/// Quit Everything never claims that agents ended without proof (R96 + P2-9).
/// The proof is acpmux's locks, never a pid: the daemon holds daemon.lock
/// for its life, each agent host holds hosts/<session>.<nonce>.live. A
/// shutting-down daemon removes its socket first, so a missing socket with
/// daemon.lock held is a shutdown in progress; a stale daemon.pid (even one
/// a live process reuses) proves nothing.
struct AcpmuxQuitProofTests {
    /// A temporary acpmux home; the locks this test "holds" stay open until
    /// the home is released.
    final class Home {
        let url: URL
        private var heldFDs: [Int32] = []

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-proof-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("hosts"), withIntermediateDirectories: true)
        }

        deinit {
            heldFDs.forEach { close($0) }
            try? FileManager.default.removeItem(at: url)
        }

        func pidFile(_ pid: Int32) throws {
            try "\(pid)\n".write(to: url.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)
        }

        /// Creates `name` under the home; `held` takes its exclusive lock
        /// through another open file, as the owning process would.
        func lockFile(_ name: String, held: Bool) {
            let fd = open(url.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard held else {
                close(fd)
                return
            }
            flock(fd, LOCK_EX)
            heldFDs.append(fd)
        }

        func host(_ session: String, nonce: String = "ab12", hostPID: Int32 = 999_999, lock: Bool?) throws {
            let record = #"{"record_version":1,"session_id":"\#(session)","host_pid":\#(hostPID),"incarnation":"i","start_nonce":"\#(nonce)"}"#
            try record.write(to: url.appendingPathComponent("hosts/\(session).json"), atomically: true, encoding: .utf8)
            if let lock { lockFile("hosts/\(session).\(nonce).live", held: lock) }
        }

        var environment: AcpmuxEnvironment {
            AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: url,
                              socketPath: url.appendingPathComponent("acpmux.sock").path, daemonArguments: [], childEnvironment: [:])
        }
    }

    @Test func aHeldDaemonLockWithoutASocketIsAShutdownInProgress() async throws {
        let home = try Home()
        try home.pidFile(getpid())
        home.lockFile("daemon.lock", held: true)
        #expect(AcpmuxQuitProof.read(home: home.url).daemon == .held)
        let result = await AcpmuxQuit.endAgents(home.environment, waitForShutdown: false)
        #expect(result == .shutdownInProgress(pid: getpid()))
    }

    /// The durable review's case: a stale daemon.pid that a live process
    /// reuses (this test's own pid) with no lock held is no daemon.
    @Test func aStalePidReusedByALiveProcessWithoutTheLockIsNoDaemon() async throws {
        let home = try Home()
        try home.pidFile(getpid())
        home.lockFile("daemon.lock", held: false)
        #expect(AcpmuxQuitProof.read(home: home.url).daemon == .free)
        #expect(await AcpmuxQuit.endAgents(home.environment, waitForShutdown: false) == .noDaemon)
        #expect(await AcpmuxQuit.endAgents(home.environment, waitForShutdown: true, within: .milliseconds(50)) == .noDaemon)
    }

    /// A stale host record with a live host_pid but no held lock is not a
    /// running agent; a held lock is.
    @Test func onlyHeldHostLocksCount() throws {
        let home = try Home()
        try home.host("alive", lock: true)
        try home.host("stale", hostPID: getpid(), lock: false)
        try home.host("nolock", hostPID: getpid(), lock: nil)
        let facts = AcpmuxQuitProof.read(home: home.url)
        #expect(facts.liveHostSessions == ["alive"])
        #expect(facts.unknownHostSessions.isEmpty)
    }

    @Test func anUnreadableHostRecordIsUnknownAndNeverSuccess() throws {
        let home = try Home()
        try "{not json".write(to: home.url.appendingPathComponent("hosts/broken.json"), atomically: true, encoding: .utf8)
        let facts = AcpmuxQuitProof.read(home: home.url)
        #expect(facts.unknownHostSessions == ["broken"])
        #expect(AcpmuxQuitProof.decide(facts, chief: [], daemonExited: true) == .agentsStillRunning(["broken"]))
    }

    @Test func theDecisionNeedsAFreeDaemonLockAndNoNonChiefHost() {
        #expect(AcpmuxQuitProof.decide(.init(daemon: .held, daemonPID: 42), chief: [], daemonExited: false) == .shutdownInProgress(pid: 42))
        #expect(AcpmuxQuitProof.decide(.init(daemon: .unknown), chief: [], daemonExited: true) == .shutdownInProgress(pid: nil),
                "a lock that cannot be probed is never success")
        let hosts = AcpmuxQuitProof.Facts(daemon: .free, liveHostSessions: ["a", "chief"])
        #expect(AcpmuxQuitProof.decide(hosts, chief: ["chief"], daemonExited: false) == .agentsStillRunning(["a"]))
        let chiefOnly = AcpmuxQuitProof.Facts(daemon: .free, liveHostSessions: ["chief"])
        #expect(AcpmuxQuitProof.decide(chiefOnly, chief: ["chief"], daemonExited: false) == .noDaemon, "the Chief keeps running by design")
        #expect(AcpmuxQuitProof.decide(.init(daemon: .free), chief: [], daemonExited: true) == .ended)
    }

    /// Retry waits for the shutdown in progress; a daemon that does not end
    /// in time stays "in progress", never success.
    @Test func retryWaitsAndStaysInProgressWhileTheLockIsHeld() async throws {
        let home = try Home()
        try home.pidFile(getpid())
        home.lockFile("daemon.lock", held: true)
        let result = await AcpmuxQuit.endAgents(home.environment, waitForShutdown: true, within: .milliseconds(50))
        #expect(result == .shutdownInProgress(pid: getpid()))
    }

    @Test func noDaemonAndNoHostsIsNoDaemon() async throws {
        #expect(await AcpmuxQuit.endAgents(try Home().environment, waitForShutdown: false) == .noDaemon)
    }

    /// The census at dialog open uses the same proof.
    @Test func theCensusWithoutASocketFollowsTheLocks() async throws {
        let shuttingDown = try Home()
        shuttingDown.lockFile("daemon.lock", held: true)
        #expect(await AcpmuxQuit.census(shuttingDown.environment) == nil, "agents unknown during a shutdown")
        let orphans = try Home()
        try orphans.host("a", lock: true)
        try orphans.host("b", lock: false)
        #expect(await AcpmuxQuit.census(orphans.environment)?.live == 1)
        #expect(await AcpmuxQuit.census(try Home().environment) == AcpmuxSessionCensus())
    }
}
