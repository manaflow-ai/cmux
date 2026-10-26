import AppKit
import CmuxNextDesign
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

    /// An ssh machine's sidebar tooltip line: its target's latest state, found by host whatever its
    /// case, and none for a machine with no update state.
    @Test @MainActor func theBoardGivesAnSSHMachinesTooltipLine() {
        let board = DaemonUpdateBoard()
        #expect(board.detail(sshHost: "cmux16") == nil)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16",
                                      state: .failed(reason: "disk full", rolledBack: false)))
        let line = DaemonUpdateBoard.line(.failed(reason: "disk full", rolledBack: false))
        #expect(line.contains("disk full"))
        #expect(board.detail(sshHost: "CMUX16") == line)
        #expect(board.detail(id: "acpmux-peer:cmux16") == line)
        #expect(board.detail(sshHost: "huge-blue") == nil)
        // Two targets on one host (an ssh peer and a Cloud machine reached over ssh): the lowest id's line.
        board.apply(DaemonUpdateEvent(id: "z-cloud:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .updating))
        #expect(board.detail(sshHost: "cmux16") == line)
        #expect(DaemonUpdateBoard.line(.updated(build: "abc123def 2026-10-20")).contains("abc123def 2026-10-20"))
        #expect(DaemonUpdateBoard.line(.failed(reason: "new daemon reported 0123456ff", rolledBack: true)).contains("0123456ff"))
        #expect(!DaemonUpdateBoard.line(.updating).isEmpty && !DaemonUpdateBoard.line(.retrying).isEmpty)
    }

    /// A recorded failure or rollback the policy asks a notice for shows one toast naming the
    /// machine; the same state without the ask, or any other state, shows none.
    @Test @MainActor func aFailureTheBoardIsAskedToNoticeShowsOneToast() {
        let board = DaemonUpdateBoard()
        var shown: [String] = []
        board.showNotice = { shown.append($0.message) }
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16", state: .updating, notify: true))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16",
                                      state: .failed(reason: "disk full", rolledBack: false)))
        #expect(shown.isEmpty)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", sshHost: "cmux16",
                                      state: .failed(reason: "disk full", rolledBack: false), notify: true))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:huge-blue", displayName: "huge-blue", sshHost: "huge-blue",
                                      state: .failed(reason: "new daemon reported 0123456ff", rolledBack: true), notify: true))
        #expect(shown.count == 2)
        #expect(shown.first?.contains("cmux16") == true && shown.first?.contains("disk full") == true)
        #expect(shown.last?.contains("huge-blue") == true && shown.last?.contains("0123456ff") == true)
    }

    /// Each failed target and build is a toast of its own: the toast center replaces a same-id toast
    /// and keeps a closed one quiet, so a later build's failure, or another machine of the same name
    /// failing for the same reason, must not share an id with an earlier one. The same event again
    /// keeps its id, and replaces its toast in place.
    @Test @MainActor func eachFailedTargetAndBuildIsAToastOfItsOwn() throws {
        func failed(_ id: String, build: String?) -> DaemonUpdateEvent {
            DaemonUpdateEvent(id: id, displayName: "cmux16", sshHost: "cmux16", state: .failed(reason: "disk full", rolledBack: false),
                              notify: true, build: build)
        }
        let first = try #require(DaemonUpdateBoard.noticeToast(failed("acpmux-peer:cmux16", build: "abc123def")))
        let laterBuild = try #require(DaemonUpdateBoard.noticeToast(failed("acpmux-peer:cmux16", build: "fedcba987")))
        let otherMachine = try #require(DaemonUpdateBoard.noticeToast(failed("cloud:cmux16", build: "abc123def")))
        #expect(first.message == laterBuild.message && first.message == otherMachine.message)
        #expect(first.id != laterBuild.id, "a later build's failure")
        #expect(first.id != otherMachine.id, "another machine of the same name and reason")
        #expect(DaemonUpdateBoard.noticeToast(failed("acpmux-peer:cmux16", build: "abc123def"))?.id == first.id, "the same event again")
        #expect(first.duration == CmuxToast.untilClosed)
        #expect(DaemonUpdateBoard.noticeToast(DaemonUpdateEvent(id: "acpmux-peer:cmux16", displayName: "cmux16", state: .updating,
                                                                notify: true)) == nil)
    }

    /// An update fails in the background, while the app is not active: AppKit then has no key and
    /// no main window, and the toast still goes to the app's frontmost window, not nowhere.
    @Test @MainActor func aNoticeWithTheAppInTheBackgroundGoesToItsFrontWindow() {
        let behind = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        let front = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [panel, front, behind], visible: { _ in true }) === front)
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [front, behind], visible: { $0 === behind }) === behind,
                "a window that is not shown is skipped")
        #expect(DaemonUpdateBoard.noticeWindow(key: behind, main: front, ordered: [front], visible: { _ in true }) === behind, "the key window first")
        #expect(DaemonUpdateBoard.noticeWindow(key: nil, main: nil, ordered: [], visible: { _ in true }) == nil)
    }
}
