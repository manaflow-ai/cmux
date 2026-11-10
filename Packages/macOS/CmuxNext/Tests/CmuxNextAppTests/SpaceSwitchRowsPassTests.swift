import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A space switch back to a space where nothing changed computes no sections (SPACE SWITCH 3, F3): the rows pass
/// walked every workspace of the session on each switch. Counts, no clock. And the kept rows are never stale: a
/// workspace that comes, goes or moves while its space is hidden shows right after the switch back.
@MainActor
@Suite(.serialized)
struct SpaceSwitchRowsPassTests {
    /// The workspace rows the sidebar's model lists now.
    private func listed(_ bench: SpaceSwitchBench) -> Set<String> {
        Set(bench.controller.sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue))
    }

    @Test(arguments: [20, 826])
    func aSwitchBackComputesNoSections(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, panes: true, registered: true)
        defer { bench.close() }
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        let keep = bench.controller.sidebar.rowsKeep
        for round in 0..<6 {
            let room = bench.rooms[(round + 1) % 2], other = bench.rooms[round % 2]
            let before = keep.computes
            _ = try await bench.settledSwitch(to: room)
            #expect(keep.computes == before, "switch \(round) back to a space with no change computed its sections \(keep.computes - before) time(s) at \(total) workspaces")
            let rows = listed(bench)
            #expect(rows.isSuperset(of: bench.keysByRoom[room] ?? []), "switch \(round) does not list every workspace of its space")
            #expect(rows.isDisjoint(with: bench.keysByRoom[other] ?? []), "switch \(round) lists a workspace of the space it left")
        }
    }

    @Test func aWorkspaceThatLeftWhileItsSpaceWasHiddenIsNotListedAfterTheSwitchBack() async throws {
        let bench = try await SpaceSwitchBench(total: 20, panes: true, registered: true)
        defer { bench.close() }
        let store = bench.services.machines.local.store
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        // While room 0 is hidden: its workspace k4 closes.
        var live = bench.tree
        live.workspaces.removeAll { $0.key?.rawValue == "k4" }
        live.personal?.pins.removeAll { $0.workspaceKey.rawValue == "k4" }
        live.personal?.workspaces.removeAll { $0.workspaceKey.rawValue == "k4" }
        store.apply(snapshot: live)
        store.advanceAppliedSequence(to: store.appliedSequence + 1)
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        let rows = listed(bench)
        #expect(!rows.contains("k4"), "the closed workspace is still listed after the switch back")
        #expect(rows.contains("k2"), "the space lost a workspace that did not change")
    }

    @Test func aWorkspaceThatCameWhileItsSpaceWasHiddenIsListedAfterTheSwitchBack() async throws {
        let bench = try await SpaceSwitchBench(total: 20, panes: true, registered: true)
        defer { bench.close() }
        let store = bench.services.machines.local.store
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        // While room 0 is hidden: k5 of room 1 moves to room 0 (its pin changes).
        var live = bench.tree
        if let pin = live.personal?.pins.firstIndex(where: { $0.workspaceKey.rawValue == "k5" }) { live.personal?.pins[pin].profile = bench.rooms[0] }
        store.apply(snapshot: live)
        store.advanceAppliedSequence(to: store.appliedSequence + 1)
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        #expect(listed(bench).contains("k5"), "the workspace that moved to the space while it was hidden is not listed after the switch back")
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        #expect(!listed(bench).contains("k5"), "the workspace that left the space is still listed there")
    }

    @Test func aWorkspaceThatMovedToAnotherWindowWhileItsSpaceWasHiddenIsNotListedAfterTheSwitchBack() async throws {
        let bench = try await SpaceSwitchBench(total: 20, panes: true, registered: true)
        defer { bench.close() }
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        // While room 0 is hidden: its workspace k6 goes to another window.
        bench.services.windows.registry.apply { $0.openWindow(id: "other", workspaceIDs: ["k6"]) }
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        let rows = listed(bench)
        #expect(!rows.contains("k6"), "the workspace another window took is still listed after the switch back")
        #expect(rows.contains("k2"), "the space lost a workspace that did not change")
    }
}
