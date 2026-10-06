import Darwin
import Foundation
import Testing
import CmuxNextAgentPane
@testable import CmuxNextApp

/// Quit, end sessions ends the Chief host too (home-state-ownership.md
/// section 3); a quit that keeps sessions keeps it. On sbmix-v4
/// (cmux-lawrence-2, 2026-10-06) the host outlived End Sessions with ppid 1.
@Suite struct ChiefHostStopTests {
    static func home() throws -> (ChiefHome, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-stop-\(UUID().uuidString)", isDirectory: true)
        let lock = root.appendingPathComponent("state/host.lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (ChiefHome(root: root, isolated: false), lock)
    }

    static func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func endingSessionsStopsTheHostThatHoldsTheChiefHomesLock() async throws {
        let (home, lockFile) = try Self.home()
        let host = try Self.sleeper()
        try Data("\(host.processIdentifier)\n1\nflock\n".utf8).write(to: lockFile)
        let held = try #require(ChiefMigration.HostLock(path: lockFile), "the host holds its lock")
        defer { held.release() }
        let pid = host.processIdentifier
        let stopped = await ChiefHostStop.stop(home: home, isChiefHost: { $0 == pid })
        #expect(stopped == host.processIdentifier)
        host.waitUntilExit()
        #expect(host.terminationReason == .uncaughtSignal)
    }

    /// Every session of the Chief home's acpmux is the Chief's: the Chief
    /// itself, its sub-agents and the compactor's slots. End Sessions ends
    /// them all; a tag's acpmux keeps the Home Chief's. On onehist-import-v6
    /// (cmux-lawrence-2, 2026-10-06) seven compactor slots kept running
    /// with ppid 1 after End Sessions.
    @Test func endingSessionsKeepsNoChiefAgentInTheChiefHome() {
        let sessions: [String: Any] = ["sessions": [
            ["sessionId": "s-chief", "name": "optchat-chief-94fbe51e"],
            ["sessionId": "s-slot", "harness": "optchat-compact-94fbe51e-slot-2"],
            ["sessionId": "s-sub", "tags": ["cmux.chief": "sub"]],
            ["sessionId": "s-other", "name": "claude-1"],
        ]]
        #expect(AcpmuxQuit.keptSessions(sessions, keep: ChiefHostStop.endSessionsKeep).isEmpty)
        #expect(Set(AcpmuxQuit.keptSessions(sessions, keep: .chief)) == ["s-chief", "s-slot", "s-sub"])
    }

    @Test func nothingIsStoppedWithoutAHostHoldingTheLock() async throws {
        let (home, lockFile) = try Self.home()
        let other = try Self.sleeper()
        defer { other.terminate() }
        // A stale lock text naming a live process that is not the host.
        try Data("\(other.processIdentifier)\n1\nflock\n".utf8).write(to: lockFile)
        #expect(await ChiefHostStop.stop(home: home, isChiefHost: { _ in true }) == nil, "no host holds the lock")
        let held = try #require(ChiefMigration.HostLock(path: lockFile))
        defer { held.release() }
        #expect(await ChiefHostStop.stop(home: home, isChiefHost: { _ in false }) == nil, "the pid is not an optchat-chief host")
        #expect(other.isRunning)
    }
}
