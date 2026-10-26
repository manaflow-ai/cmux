import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The words of the daemon update (``DaemonUpdateTarget``): how a build string reads, the ledger
/// that keeps one attempt per machine and build, the board, and the toggle.
@Suite nonisolated struct DaemonUpdateTargetTests {
    @Test func toggleIsOnByDefaultAndInDebugSettings() {
        #expect(AgentPaneTunables.updatePeersAutomatically.defaultValue)
        #expect(AgentPaneTunables.all.contains { $0.key == AgentPaneTunables.updatePeersAutomatically.key })
    }

    @Test func buildCommitReadsHashDirtyAndDate() throws {
        let clean = try #require(DaemonBuildCommit("ABC123DEF 2026-10-20"))
        #expect(clean.hash == "abc123def" && !clean.dirty && clean.date == "2026-10-20")
        #expect(DaemonBuildCommit("abc123def")?.date == nil)
        #expect(DaemonBuildCommit("abc123def 2026-1-20")?.date == nil)
        #expect(try #require(DaemonBuildCommit("fedcba987 2026-10-21")).isNewer(than: clean))
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987 2026-10-21"))))
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987 2026-10-20"))), "one day orders nothing")
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987"))), "no date orders nothing")
        #expect(clean.sameCommit("abc123def0123456789abcdef0123456789abcd"))
        #expect(!clean.sameCommit("abc123dee0123456789abcdef0123456789abcd"))
        #expect(try #require(DaemonBuildCommit("abc123def+dirty.00ff00ff 2026-10-20")).dirty)
        #expect(DaemonBuildCommit("nogit 2026-10-20") == nil)
        #expect(DaemonBuildCommit(nil) == nil)
        #expect(DaemonBuildCommit("") == nil)
    }

    @Test func theLedgerKeepsOneBuildsOutcomesAcrossLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def") == DaemonUpdateLedger(build: "abc123def"))
        try DaemonUpdateLedger(build: "abc123def", targets: ["acpmux-peer:huge-blue": "rolledBack"]).write(directory)
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").targets == ["acpmux-peer:huge-blue": "rolledBack"])
        // A new build starts an empty ledger.
        #expect(DaemonUpdateLedger.read(directory, build: "fedcba987").targets.isEmpty)
    }

    @Test @MainActor func theBoardKeepsEachTargetsLatestStateAndForgetsACleared() {
        let board = DaemonUpdateBoard()
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .updating))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .retrying))
        #expect(board.targets["acpmux-peer:cmux16"]?.state == .retrying)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", state: .cleared))
        #expect(board.targets.isEmpty)
    }
}
