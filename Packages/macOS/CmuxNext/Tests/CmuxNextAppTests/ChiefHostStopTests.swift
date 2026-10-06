import Darwin
import Foundation
import Testing
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

    @Test func endingSessionsStopsTheHostThatHoldsTheChiefHomesLock() throws {
        let (home, lockFile) = try Self.home()
        let host = try Self.sleeper()
        try Data("\(host.processIdentifier)\n1\nflock\n".utf8).write(to: lockFile)
        let held = try #require(ChiefMigration.HostLock(path: lockFile), "the host holds its lock")
        defer { held.release() }
        let stopped = ChiefHostStop.stop(home: home, isChiefHost: { $0 == host.processIdentifier })
        #expect(stopped == host.processIdentifier)
        host.waitUntilExit()
        #expect(host.terminationReason == .uncaughtSignal)
    }

    @Test func nothingIsStoppedWithoutAHostHoldingTheLock() throws {
        let (home, lockFile) = try Self.home()
        let other = try Self.sleeper()
        defer { other.terminate() }
        // A stale lock text naming a live process that is not the host.
        try Data("\(other.processIdentifier)\n1\nflock\n".utf8).write(to: lockFile)
        #expect(ChiefHostStop.stop(home: home, isChiefHost: { _ in true }) == nil, "no host holds the lock")
        let held = try #require(ChiefMigration.HostLock(path: lockFile))
        defer { held.release() }
        #expect(ChiefHostStop.stop(home: home, isChiefHost: { _ in false }) == nil, "the pid is not an optchat-chief host")
        #expect(other.isRunning)
    }
}
