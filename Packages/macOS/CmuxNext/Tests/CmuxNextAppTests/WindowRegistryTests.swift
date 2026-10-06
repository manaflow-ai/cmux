import CmuxNextDaemon
import CoreGraphics
import Foundation
@testable import CmuxNextApp
import Testing

/// `WindowRegistry`: every workspace in exactly one window, a window exists
/// only while it owns at least one workspace (the last one leaving closes
/// it, the only window too), closing a window never drops workspaces, and
/// membership survives a save/restore.
struct WindowRegistryTests {
    /// Window a lists w1 w2, window b lists w3 (b most recent).
    private func twoWindows() -> WindowRegistry {
        var registry = WindowRegistry()
        registry.openWindow(id: "a", workspaceIDs: ["w1", "w2"])
        registry.openWindow(id: "b", workspaceIDs: ["w3"])
        return registry
    }

    @Test func openingAWindowTakesItsWorkspacesFromTheirOwners() {
        var registry = twoWindows()
        let changes = registry.openWindow(id: "c", workspaceIDs: ["w2"])
        #expect(registry.window("a")?.workspaceIDs == ["w1"])
        #expect(registry.window("c")?.workspaceIDs == ["w2"])
        #expect(changes.moved == ["c": ["w2"]])
        #expect(registry.violations().isEmpty)
    }

    @Test func movingTheLastWorkspaceClosesTheWindow() {
        var registry = twoWindows()
        let changes = registry.move(["w3"], to: "a", before: "w2")
        #expect(registry.window("a")?.workspaceIDs == ["w1", "w3", "w2"])
        #expect(registry.window("b") == nil)
        #expect(changes.emptied == ["b"])
        #expect(registry.violations().isEmpty)
    }

    @Test func tearingOffEveryWorkspaceOfAWindowClosesIt() {
        var registry = twoWindows()
        let changes = registry.openWindow(id: "c", workspaceIDs: ["w1", "w2"])
        #expect(changes.emptied == ["a"])
        #expect(registry.openWindows.map(\.id) == ["b", "c"])
        #expect(registry.violations().isEmpty)
    }

    @Test func theOnlyWindowClosesWhenItsLastWorkspaceIsGone() {
        var registry = WindowRegistry()
        registry.openWindow(id: "a", workspaceIDs: ["w1"])
        let changes = registry.reconcile(live: [], dead: ["w1"], fallbackWindow: "unused")
        #expect(changes.emptied == ["a"])
        #expect(registry.windows.isEmpty)
        #expect(registry.violations().isEmpty)
    }

    @Test func whenEveryWindowEmptiesEveryWindowCloses() {
        var registry = twoWindows()
        registry.activate("a")
        let changes = registry.reconcile(live: [], dead: ["w1", "w2", "w3"], fallbackWindow: "unused")
        #expect(Set(changes.emptied) == ["a", "b"])
        #expect(registry.windows.isEmpty)
        #expect(registry.recency.isEmpty)
    }

    @Test func movingTheOnlyWindowsLastWorkspaceAwayClosesIt() {
        var registry = WindowRegistry()
        registry.openWindow(id: "a", workspaceIDs: ["w1"])
        let changes = registry.openWindow(id: "b", workspaceIDs: ["w1"])
        #expect(changes.emptied == ["a"])
        #expect(registry.windows.map(\.id) == ["b"])
        #expect(registry.violations().isEmpty)
    }

    @Test func aWindowIsNeverRegisteredWithoutAWorkspace() {
        var registry = WindowRegistry()
        let changes = registry.openWindow(id: "a")
        #expect(changes.isEmpty)
        #expect(registry.windows.isEmpty)
        // A window that would take only workspaces it cannot own stays out too.
        registry.openWindow(id: "b", workspaceIDs: [])
        #expect(registry.window("b") == nil)
    }

    @Test func aRegisteredEmptyWindowIsAViolation() {
        let registry = WindowRegistry(windows: [WindowRegistry.Window(id: "a"), WindowRegistry.Window(id: "b", workspaceIDs: ["w1"])])
        #expect(registry.violations() == ["a has no workspaces"])
    }

    @Test func aClosedLastWindowIsDroppedWhenItsWorkspacesDie() {
        var registry = WindowRegistry()
        registry.openWindow(id: "a", workspaceIDs: ["w1"])
        registry.close("a")
        #expect(registry.window("a")?.isOpen == false)
        let changes = registry.reconcile(live: [], dead: ["w1"], fallbackWindow: "unused")
        #expect(changes.emptied == ["a"])
        #expect(registry.windows.isEmpty)
        #expect(registry.reopen() == nil)
    }

    @Test func closingAWindowMovesItsWorkspacesToTheMostRecentOther() {
        var registry = twoWindows()
        registry.openWindow(id: "c", workspaceIDs: ["w4"])
        registry.activate("b")
        let changes = registry.close("c")
        #expect(registry.window("c") == nil)
        #expect(registry.window("b")?.workspaceIDs == ["w3", "w4"])
        #expect(changes.moved == ["b": ["w4"]])
        #expect(registry.violations().isEmpty)
    }

    @Test func closingTheLastWindowKeepsItRestorable() {
        var registry = WindowRegistry()
        registry.openWindow(id: "a", workspaceIDs: ["w1", "w2"])
        registry.close("a")
        #expect(registry.window("a")?.isOpen == false)
        #expect(registry.window("a")?.workspaceIDs == ["w1", "w2"])
        #expect(registry.openWindows.isEmpty)
        #expect(registry.reopen() == "a")
        #expect(registry.window("a")?.isOpen == true)
        #expect(registry.reopen() == nil)
    }

    @Test func reconcileDropsDeadOrdersLikeTheDaemonAndAdoptsOrphans() {
        var registry = twoWindows()
        registry.activate("a")
        // w2 is gone, w9's machine is still connecting (not dead), w5 is new.
        registry.move(["w9"], to: "b")
        registry.reconcile(live: ["w5", "w3", "w1"], dead: ["w2"], fallbackWindow: "unused")
        #expect(registry.window("a")?.workspaceIDs == ["w5", "w1"])
        #expect(registry.window("b")?.workspaceIDs == ["w3", "w9"])
        #expect(registry.violations().isEmpty)
    }

    @Test func reconcilePlacesClaimedOrphansInTheirWindow() {
        var registry = twoWindows()
        registry.activate("a")
        let changes = registry.reconcile(live: ["w1", "w2", "w3", "w6"], dead: [], placements: ["w6": "b"], fallbackWindow: "unused")
        #expect(registry.window("b")?.workspaceIDs == ["w3", "w6"])
        #expect(changes.moved == ["b": ["w6"]])
    }

    @Test func reconcileWithNoWindowRegistersTheFallback() {
        var registry = WindowRegistry()
        registry.reconcile(live: ["w1", "w2"], dead: [], fallbackWindow: "fresh")
        #expect(registry.windows.map(\.id) == ["fresh"])
        #expect(registry.window("fresh")?.workspaceIDs == ["w1", "w2"])
        #expect(registry.violations().isEmpty)
    }

    @Test func selectionRepairPrefersMovedInThenKeepsThenFallsToNeighbor() {
        #expect(WindowRegistry.repairedSelection(current: "w1", previous: ["w1"], members: ["w1", "w7"], preferred: ["w7"]) == "w7")
        #expect(WindowRegistry.repairedSelection(current: "w2", previous: ["w1", "w2"], members: ["w1", "w2", "w3"]) == "w2")
        #expect(WindowRegistry.repairedSelection(current: "w2", previous: ["w1", "w2", "w3"], members: ["w1", "w3"]) == "w3")
        #expect(WindowRegistry.repairedSelection(current: "w3", previous: ["w1", "w2", "w3"], members: ["w1", "w2"]) == "w2")
        #expect(WindowRegistry.repairedSelection(current: "w3", previous: [], members: []) == nil)
        #expect(WindowRegistry.repairedSelection(current: nil, previous: [], members: ["w4"]) == "w4")
    }

    // MARK: Persistence

    @Test func membershipRoundTripsThroughWindowRecords() throws {
        var registry = twoWindows()
        registry.setGeometry("a", frame: CGRect(x: 10, y: 20, width: 800, height: 600), display: "D1")
        let stateA = WindowState(id: "a", workspaceID: "w2")
        stateA.sidebarWidth = 250
        stateA.sidebarHidden = true
        stateA.activeScreenID = "screen_2"
        let records = [
            try #require(registry.record("a", state: stateA, order: 1, selectedTabs: ["p1": "t1"])),
            try #require(registry.record("b", state: nil, order: 0)),
        ]
        var document = WindowStateDocument(windows: records)
        document.prune(liveWorkspaces: ["w1", "w2", "w3"])
        let decoded = try JSONDecoder().decode(WindowStateDocument.self, from: JSONEncoder().encode(document))
        let restored = WindowRegistry(records: decoded.windows)
        #expect(restored.window("a")?.workspaceIDs == ["w1", "w2"])
        #expect(restored.window("a")?.frame == CGRect(x: 10, y: 20, width: 800, height: 600))
        #expect(restored.window("a")?.display == "D1")
        #expect(restored.window("b")?.workspaceIDs == ["w3"])
        #expect(restored.recency.first == "b")
        let state = WindowState(record: try #require(decoded.windows.first { $0.id == "a" }))
        #expect(state.workspaceID == "w2")
        #expect(state.sidebarWidth == 250)
        #expect(state.sidebarHidden)
        #expect(state.activeScreenID == "screen_2")
        #expect(state.selection.selection(in: "p1") == "t1")
        #expect(restored.violations().isEmpty)
    }

    @Test func legacyRecordsSharingAWorkspaceKeepItInTheFrontWindow() {
        let records = [
            WindowRecord(id: "back", workspaceKey: "w1", order: 1),
            WindowRecord(id: "front", workspaceKey: "w1", order: 0),
            WindowRecord(id: "other", workspaceKey: "w2", order: 2),
        ]
        let registry = WindowRegistry(records: records)
        #expect(registry.windows.map(\.id) == ["front", "other"])
        #expect(registry.window("front")?.workspaceIDs == ["w1"])
        #expect(registry.violations().isEmpty)
    }

    @Test func emptyWindowRecordsArePrunedAndNeverRestored() {
        // Older builds saved the only window's empty state as a record with
        // no workspaces; another client can write one too.
        var document = WindowStateDocument(windows: [WindowRecord(id: "solo", order: 0), WindowRecord(id: "full", workspaceKey: "w1", order: 1)])
        document.prune(liveWorkspaces: ["w1"])
        #expect(document.windows.map(\.id) == ["full"])
        let restored = WindowRegistry(records: [WindowRecord(id: "solo", order: 0), WindowRecord(id: "full", workspaceKey: "w1", order: 1)])
        #expect(restored.windows.map(\.id) == ["full"])
        #expect(WindowRegistry(records: [WindowRecord(id: "solo")]).windows.isEmpty)
    }

    // MARK: Sidebar mapping

    @Test func filteredSidebarSlotsMapToTheDaemonOrder() {
        // Daemon order w1 w2 w3 w4 w5; this window lists w2 and w4.
        let global = ["w1", "w2", "w3", "w4", "w5"]
        #expect(SidebarMembership.globalIndex(localIndex: 0, local: ["w2", "w4"], global: global) == 1)
        #expect(SidebarMembership.globalIndex(localIndex: 1, local: ["w2", "w4"], global: global) == 3)
        #expect(SidebarMembership.globalIndex(localIndex: 2, local: ["w2", "w4"], global: global) == 4)
        #expect(SidebarMembership.globalIndex(localIndex: 0, local: [], global: global) == 5)
    }

    /// The sidebar order the personal store produces: workspaces with a
    /// personal position in that order, then the rest in daemon order
    /// (PersonalSidebar.order), after `plan` is applied.
    private static func shownOrder(after plan: [SidebarMembership.PersonalPlacement], rowed: [String], daemon: [String]) -> [String] {
        var rowed = rowed
        for step in plan {
            rowed.removeAll { $0 == step.key }
            rowed.insert(step.key, at: min(max(step.index, 0), rowed.count))
        }
        return rowed.filter(daemon.contains) + daemon.filter { !rowed.contains($0) }
    }

    /// GUI repro (sidebar lead 2026-10-05, sbrow-v1 on cmux-lawrence-2):
    /// new workspaces have no personal position yet and show after the
    /// positioned ones. A drop at or among them landed somewhere else, because
    /// an index into the positioned order cannot name a slot among the rest.
    @Test func aDropAmongWorkspacesWithoutAPersonalPositionLandsWhereItShowed() throws {
        let daemon = ["x", "r1", "r2", "r3", "r4", "r5", "r6"]
        // Only "x" has a personal position; r1...r6 show after it in daemon order.
        let cases: [(moving: String, rowed: [String], slot: Int, expected: [String])] = [
            // r2 to the end (the shown slot after r6).
            ("r2", ["x"], 6, ["x", "r1", "r3", "r4", "r5", "r6", "r2"]),
            // r5 between r1 and r2.
            ("r5", ["x"], 2, ["x", "r1", "r5", "r2", "r3", "r4", "r6"]),
            // r1 to the end after r2 got a position.
            ("r1", ["x", "r2"], 6, ["x", "r2", "r3", "r4", "r5", "r6", "r1"]),
            // Every workspace positioned: the plain case still holds.
            ("r1", ["x", "r2", "r3", "r4", "r5", "r6"], 3, ["x", "r2", "r3", "r1", "r4", "r5", "r6"]),
        ]
        for c in cases {
            let rowed = c.rowed.filter { $0 != c.moving }
            let before = Self.shownOrder(after: [], rowed: c.rowed, daemon: daemon)
            let shown = before.filter { $0 != c.moving }
            try #require(c.slot <= shown.count)
            let plan = SidebarMembership.personalPlacements(moving: [c.moving], localIndex: c.slot, shown: shown, rowed: rowed)
            #expect(Self.shownOrder(after: plan, rowed: rowed, daemon: daemon) == c.expected, "\(c.moving) to slot \(c.slot)")
            #expect(plan.last?.key == c.moving, "the moved workspace is placed last")
        }
    }

    @Test func offscreenFramesMoveToTheirSavedDisplay() {
        let screens: [(id: String?, visible: CGRect)] = [("main", CGRect(x: 0, y: 0, width: 1000, height: 800)),
                                                          ("side", CGRect(x: 1000, y: 0, width: 1000, height: 800))]
        let onScreen = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(WindowPlacementFallback.place(onScreen, display: "side", screens: screens) == onScreen)
        let lost = CGRect(x: 5000, y: 5000, width: 600, height: 400)
        #expect(WindowPlacementFallback.place(lost, display: "side", screens: screens) == CGRect(x: 1200, y: 200, width: 600, height: 400))
        #expect(WindowPlacementFallback.place(lost, display: "gone", screens: screens) == CGRect(x: 200, y: 200, width: 600, height: 400))
    }
}
