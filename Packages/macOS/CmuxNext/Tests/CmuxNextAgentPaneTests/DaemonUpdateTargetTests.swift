import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The words of the daemon update (``DaemonUpdateTarget``): how a build string reads, the ledger
/// that keeps one attempt per machine and build, the board, and the toggle.
@Suite(.closesItsWindows) nonisolated struct DaemonUpdateTargetTests {
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

    /// A machine that cannot update in place is kept across builds; a ledger written before that
    /// field still reads (it is no unreadable ledger that blocks every target).
    @Test func theLedgerKeepsCannotUpdateAcrossBuildsAndReadsAnOlderFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"build":"abc123def","targets":{"cloud:vm-1":"failed"}}"#.utf8).write(to: DaemonUpdateLedger.file(in: directory))
        #expect(DaemonUpdateLedger.read(directory, build: "abc123def") == DaemonUpdateLedger(build: "abc123def", targets: ["cloud:vm-1": "failed"]))
        let tooOld = DaemonUpdateLedger.CannotUpdate(build: "0123456ff", reason: "too old to update in place")
        try DaemonUpdateLedger(build: "abc123def", targets: ["cloud:vm-1": "unsupported"], cannotUpdate: ["cloud:vm-1": tooOld]).write(directory)
        let next = DaemonUpdateLedger.read(directory, build: "fedcba987")
        #expect(next.targets.isEmpty)
        #expect(next.cannotUpdate == ["cloud:vm-1": tooOld])
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

    /// Leo, 2026-11-06, on a toast "huge-blue is still on its previous version · Connection to
    /// UNKNOWN port 65535 timed out" drawn over his message: "why is this still happening yo". No
    /// machine update state raises a toast, whatever the state: each is a line on the board.
    @Test @MainActor func noMachineUpdateStateRaisesAToast() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.orderFront(nil)
        let board = DaemonUpdateBoard()
        let lost = "Connection to UNKNOWN port 65535 timed out"
        for state: DaemonUpdateEvent.State in [.updating, .retrying, .offline, .failed(reason: lost, rolledBack: true),
                                               .failed(reason: "disk full", rolledBack: false), .cannotUpdate(reason: "too old"),
                                               .updated(build: "abc123def")] {
            board.apply(DaemonUpdateEvent(id: "acpmux-peer:huge-blue", displayName: "huge-blue", sshHost: "huge-blue", state: state, build: "abc123def"))
            #expect(CmuxToastCenter.shared.toasts(in: window).isEmpty, "a toast for \(state)")
        }
    }

    /// A failure is a quiet line on the machine's row in Settings > Updates, in plain words: a link
    /// that dropped reads "huge-blue didn't answer", never ssh's "Connection to UNKNOWN port 65535
    /// timed out"; any other reason stays after the machine's name.
    @Test @MainActor func aFailureIsAPlainRowLine() {
        let board = DaemonUpdateBoard()
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:huge-blue", displayName: "huge-blue", sshHost: "huge-blue",
                                      state: .failed(reason: "Connection to UNKNOWN port 65535 timed out", rolledBack: true)))
        #expect(board.otherMachines?.lines == ["huge-blue didn't answer"])
        #expect(board.detail(sshHost: "huge-blue") == "Didn't answer")
        #expect(board.otherMachines?.machines.first?.canUpdate == false)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box", sshHost: "build-box",
                                      state: .failed(reason: "disk full", rolledBack: false)))
        #expect(board.otherMachines?.lines.last == "huge-blue didn't answer")
        #expect(board.otherMachines?.lines.first == "Couldn't update build-box: disk full")
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:huge-blue", displayName: "huge-blue", state: .updated(build: "abc123def")))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box", state: .cleared))
        #expect(board.otherMachines == nil)
    }

    /// A machine too old to update in place is no failure: Settings > Updates lists it in one row
    /// with the failures, each machine once.
    @Test @MainActor func aMachineThatCannotUpdateHasOneSettingsLine() {
        let board = DaemonUpdateBoard()
        #expect(board.otherMachines == nil)
        let tooOld = "lofty-lemon-stoat runs a cmux too old to update in place. Its chats and terminals keep working."
        board.apply(DaemonUpdateEvent(id: "cloud:a", displayName: "lofty-lemon-stoat", state: .cannotUpdate(reason: tooOld)))
        #expect(board.detail(id: "cloud:a") == tooOld)
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box", sshHost: "build-box",
                                      state: .failed(reason: "disk full", rolledBack: false), build: "abc123def"))
        let machines = board.otherMachines
        #expect(machines?.lines.count == 2)
        #expect(machines?.lines.first == tooOld)
        #expect(machines?.lines.last?.contains("build-box") == true)
        // Updated since: off the list.
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:build-box", displayName: "build-box", state: .updated(build: "abc123def")))
        #expect(board.otherMachines?.lines == [tooOld])
    }

    /// An offline machine is one quiet line in plain words, in its tooltip and in Settings >
    /// Updates; once it updates the line goes.
    @Test @MainActor func anOfflineMachineHasOneQuietLine() {
        let board = DaemonUpdateBoard()
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:swarm-10", displayName: "swarm-10", sshHost: "swarm-10", state: .offline))
        #expect(board.detail(sshHost: "swarm-10") == DaemonUpdateBoard.line(.offline))
        #expect(board.otherMachines?.lines == [DaemonUpdateBoard.offlineLine("swarm-10")])
        #expect(board.otherMachines?.machines.first?.canUpdate == false)
        #expect(DaemonUpdateBoard.offlineLine("swarm-10").contains("swarm-10"))
        board.apply(DaemonUpdateEvent(id: "acpmux-peer:swarm-10", displayName: "swarm-10", sshHost: "swarm-10", state: .updated(build: "abc123def")))
        #expect(board.otherMachines == nil)
    }
}
