import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A space switch asks for a save of the window records (`WindowRecordSaver.stateDidChange`), and that save builds
/// the records on the main thread in the next main-actor turn, before the run loop commits the switch's frame. Its
/// build kept the remembered tab of each pane behind a key that held every daemon's applied sequence, so in a live
/// session (an agent prints, a title changes: a batch between any two switches) each save read every pane of every
/// workspace of the window again: 858 observed reads, 2.7 ms of the main thread per switch at 826 workspaces
/// (`sample` of the real session, aws-m4pro-8). A tab switch paid the same walk: its own change moved the key.
/// Each test counts the panes one save reads. The size is the one argument: 60 and 826 workspaces (826 is the
/// count of the session the budget is for), one pane with two tabs in each.
@MainActor @Suite(.serialized)
struct SpaceSwitchRecordSaveTests {
    @Test(arguments: [60, 826])
    func theSaveAfterASwitchReadsNoPane(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, panes: true, registered: true)
        defer { bench.close() }
        let saver = bench.services.windows.recordSaver, store = bench.services.machines.local.store
        // Each space shown once, then the first save: it reads each pane once.
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        _ = saver.currentRecords()
        for round in 0..<6 {
            let room = bench.rooms[(round + 1) % 2]
            // A live session: a daemon batch that changes no tab list lands between two switches.
            store.advanceAppliedSequence(to: store.appliedSequence + 1)
            _ = try await bench.settledSwitch(to: room)
            let before = saver.paneReads
            let record = try #require(saver.currentRecords().first)
            let reads = saver.paneReads - before
            print("SPACE-SWITCH-RECORD-SAVE n=\(total) switch=\(round) pane_reads=\(reads) selected_tabs=\(record.selectedTabs.count)")
            #expect(reads == 0, "switch \(round) at \(total) workspaces: the save read \(reads) panes")
            #expect(record.profile == room, "the record of switch \(round) names the space the window shows")
            #expect(record.selectedTabs == rememberedTabs(bench), "the record of switch \(round) lists each pane's remembered tab")
        }
    }

    /// The remembered tab of each pane of the window's workspaces, read pane by pane: what a record must list.
    private func rememberedTabs(_ bench: SpaceSwitchBench) -> [String: String] {
        var tabs: [String: String] = [:]
        for id in bench.keysByRoom.values.joined() {
            for pane in bench.services.workspace(id: id)?.screens.flatMap(\.panes) ?? [] {
                if let tab = bench.state.selection.selection(in: pane.id) { tabs[pane.id] = tab }
            }
        }
        return tabs
    }

    /// A tab selected in one pane changes one entry of the record: the save still reads no pane of the session.
    @Test(arguments: [60, 826])
    func theSaveAfterATabSelectionReadsNoPane(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, panes: true, registered: true)
        defer { bench.close() }
        let saver = bench.services.windows.recordSaver
        // A pane of a workspace the window lists and does not show: nothing but this test selects its tabs.
        let pane = try #require(bench.services.workspace(id: "k5")?.screens.first?.panes.first)
        let tabs = pane.tabs.map(\.id)
        try #require(tabs.count == 2)
        _ = saver.currentRecords()
        for (round, tab) in [tabs[1], tabs[0], tabs[1]].enumerated() {
            bench.state.selection.select(tab, in: pane.id)
            let before = saver.paneReads
            let record = try #require(saver.currentRecords().first)
            let reads = saver.paneReads - before
            print("SPACE-SWITCH-RECORD-SAVE n=\(total) tab_selection=\(round) pane_reads=\(reads)")
            #expect(record.selectedTabs[pane.id] == tab, "the record keeps the tab selected in round \(round)")
            #expect(reads == 0, "tab selection \(round) at \(total) workspaces: the save read \(reads) panes")
            #expect(record.selectedTabs == rememberedTabs(bench), "the record of tab selection \(round) lists each pane's remembered tab")
        }
    }

    /// A snapshot of a live session: a workspace that the window lists and does not show has another name (an agent
    /// names its work), so the store applies that workspace again. No pane came or went: the save after the next
    /// switch reads no pane. (The store notes a tab order change for each workspace a snapshot applies again, so a
    /// key on its tab list revision read every pane after each such snapshot.)
    @Test(arguments: [60, 826])
    func theSaveAfterASnapshotThatMovesNoPaneReadsNoPane(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, panes: true, registered: true)
        defer { bench.close() }
        let saver = bench.services.windows.recordSaver, store = bench.services.machines.local.store
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        _ = saver.currentRecords()
        var live = bench.tree
        for round in 0..<4 {
            let room = bench.rooms[(round + 1) % 2]
            live.workspaces[5].name = "Agent step \(round)"
            store.apply(snapshot: live)
            store.advanceAppliedSequence(to: store.appliedSequence + 1)
            #expect(bench.services.workspace(id: "k5")?.name == "Agent step \(round)", "the snapshot of round \(round) did not apply")
            _ = try await bench.settledSwitch(to: room)
            let before = saver.paneReads
            let record = try #require(saver.currentRecords().first)
            let reads = saver.paneReads - before
            print("SPACE-SWITCH-RECORD-SAVE n=\(total) snapshot=\(round) pane_reads=\(reads) selected_tabs=\(record.selectedTabs.count)")
            #expect(reads == 0, "snapshot \(round) at \(total) workspaces: the save read \(reads) panes")
            #expect(record.profile == room, "the record of snapshot \(round) names the space the window shows")
            #expect(record.selectedTabs == rememberedTabs(bench), "the record of snapshot \(round) lists each pane's remembered tab")
        }
    }

    /// The record lists the remembered tabs of the panes the window holds: a pane that goes leaves the record with
    /// the next save and a pane that comes back is listed again, also when no remembered tab changed in between.
    @Test func theSaveAfterAPaneWentOrCameListsTheWindowsPanes() async throws {
        let bench = try await SpaceSwitchBench(total: 8, panes: true, registered: true)
        defer { bench.close() }
        let saver = bench.services.windows.recordSaver, store = bench.services.machines.local.store
        let pane = try #require(bench.services.workspace(id: "k5")?.screens.first?.panes.first)
        let id = pane.id, tab = try #require(pane.tabs.last?.id)
        bench.state.selection.select(tab, in: id)
        #expect(saver.currentRecords().first?.selectedTabs[id] == tab)
        var gone = bench.tree
        gone.workspaces[5].screens = []
        store.apply(snapshot: gone)
        store.advanceAppliedSequence(to: store.appliedSequence + 1) // a change of the tree comes in a batch
        #expect(bench.services.workspace(id: "k5")?.screens.isEmpty == true)
        #expect(saver.currentRecords().first?.selectedTabs[id] == nil, "the record still lists a pane that is gone")
        store.apply(snapshot: bench.tree)
        store.advanceAppliedSequence(to: store.appliedSequence + 1)
        #expect(bench.services.workspace(id: "k5")?.screens.first?.panes.first?.id == id)
        #expect(saver.currentRecords().first?.selectedTabs[id] == tab, "the record does not list the pane that came back")
    }

    /// A tab remembered for a pane that no workspace of the window holds stays out of the record: on the save that
    /// applies the change, as on the one that reads every pane.
    @Test func theSaveLeavesOutATabOfAPaneTheWindowDoesNotHold() async throws {
        let bench = try await SpaceSwitchBench(total: 8, panes: true, registered: true)
        defer { bench.close() }
        let saver = bench.services.windows.recordSaver
        _ = saver.currentRecords()
        bench.state.selection.select("tab:none", in: "pane:none")
        let record = try #require(saver.currentRecords().first)
        #expect(record.selectedTabs["pane:none"] == nil, "the record lists a pane the window does not hold")
        #expect(record.selectedTabs == rememberedTabs(bench))
    }
}
