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
        #expect(DaemonBuildCommit("abc123def 2026-1-20") == nil, "a second word that is no day")
        #expect(DaemonBuildCommit("abc123def 2026-10-20 extra") == nil)
        #expect(DaemonBuildCommit("abc123def+ 2026-10-20") == nil, "an empty suffix is not clean")
        #expect(DaemonBuildCommit("abc123def+wip 2026-10-20") == nil, "a suffix other than dirty.<8 hex>")
        #expect(DaemonBuildCommit("abc123def+dirty.123 2026-10-20") == nil)
        #expect(DaemonBuildCommit("abc12 2026-10-20") == nil, "a hash shorter than 7")
        #expect(try #require(DaemonBuildCommit("fedcba987 2026-10-21")).isNewer(than: clean))
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987 2026-10-21"))))
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987 2026-10-20"))), "one day orders nothing")
        #expect(!clean.isNewer(than: try #require(DaemonBuildCommit("fedcba987"))), "no date orders nothing")
        #expect(clean.sameCommit("abc123def0123456789abcdef0123456789abcd"))
        #expect(!clean.sameCommit("abc123dee0123456789abcdef0123456789abcd"))
        #expect(!clean.sameCommit(""), "nothing is no commit")
        #expect(!clean.sameCommit("abc"), "a prefix too short to name a commit")
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
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").attempted("acpmux-peer:huge-blue"))
        #expect(!DaemonUpdateLedger.read(directory, build: "abc123def").attempted("acpmux-peer:cmux16"))
        // A new build starts an empty ledger.
        #expect(DaemonUpdateLedger.read(directory, build: "fedcba987").targets.isEmpty)
    }

    /// A ledger file that is there but cannot be decoded may have held a rollback of this build:
    /// it blocks every target on this build (never retried), and the next build starts empty.
    @Test func anUnreadableLedgerBlocksItsBuildNotTheNext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"build":"abc123def","targets":{"acpmux-peer:huge-bl"#.utf8).write(to: DaemonUpdateLedger.file(in: directory))
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").attempted("acpmux-peer:huge-blue"))
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def").attempted("cloud:vm-1"), "also after a relaunch")
        #expect(!DaemonUpdateLedger.read(directory, build: "fedcba987").attempted("acpmux-peer:huge-blue"))
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
