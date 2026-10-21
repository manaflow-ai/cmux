import Foundation
import Testing
@testable import CmuxNextDaemon

/// A tab dropped on another workspace's sidebar row (Lawrence 2026-10-20: "it takes a long time
/// before it actually populates"). The daemon answers in ~50 ms, but its `tree-changed` comes
/// before the move's echo, so the store held the echo behind a full snapshot and the drop showed
/// nothing until then. The move is now an intent: the tab shows in its new pane in the drop's
/// turn, stays there through the daemon's events and snapshots, and goes back exactly on a refusal.
@MainActor
struct TabMoveToWorkspaceIntentTests {
    private static let source = PaneID(rawValue: 10)
    private static let landing = PaneID(rawValue: 31)
    private static let moved = SurfaceID(rawValue: 7)

    /// Workspace 1: pane 10 holds surfaces 1 and 7. Workspace 3: screen 300 (not active) with pane
    /// 30, and the active screen 301 whose active pane 31 holds surface 3 beside pane 32.
    private static func tree(movedInto pane: PaneID? = nil) -> DaemonTree {
        let movedTab = TabSnapshot(surface: moved, terminalID: "70", kind: .pty, title: "vim")
        let sourceTabs = pane == nil ? [TabSnapshot(surface: 1), movedTab] : [TabSnapshot(surface: 1)]
        let first = WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [
            ScreenSnapshot(id: 100, active: true, activePane: source, layout: .leaf(source), panes: [PaneSnapshot(id: source, tabs: sourceTabs)]),
        ])
        let landingTabs = pane == landing ? [TabSnapshot(surface: 3), movedTab] : [TabSnapshot(surface: 3)]
        let target = WorkspaceSnapshot(id: 3, key: nil, name: "workspace-3", screens: [
            ScreenSnapshot(id: 300, layout: .leaf(30), panes: [PaneSnapshot(id: 30, tabs: [TabSnapshot(surface: 2)])]),
            ScreenSnapshot(id: 301, active: true, activePane: landing,
                           layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(32), b: .leaf(landing)),
                           panes: [PaneSnapshot(id: 32, tabs: [TabSnapshot(surface: 4)]), PaneSnapshot(id: landing, tabs: landingTabs)]),
        ])
        return DaemonTree(workspaceRevision: 1, workspaces: [first, target])
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree())
        return store
    }

    /// Where the person sees the moved tab: its pane, and how many panes list it (1 = no tearing).
    private static func shown(_ store: DaemonStore) -> (pane: PaneID?, listed: Int) {
        let listed = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.surface == moved }.count
        return (store.pane(containing: moved)?.handle, listed)
    }

    @Test func theIntentLandsWhereTheDaemonAppendsTheTab() {
        let store = Self.store()
        #expect(store.workspaceMoveIntent(surface: Self.moved, into: 3) == .moveTab(surface: Self.moved, toPane: Self.landing, index: 1))
    }

    @Test func theDropShowsTheTabInItsNewPaneInTheSameTurn() throws {
        let store = Self.store()
        let intent = try #require(store.workspaceMoveIntent(surface: Self.moved, into: 3))
        store.intend(intent, transaction: .generate())

        #expect(Self.shown(store).pane == Self.landing)
        #expect(Self.shown(store).listed == 1)
        #expect(store.pane(Self.landing)?.tabs.map(\.surface) == [3, Self.moved])
        #expect(store.pane(Self.source)?.tabs.map(\.surface) == [1])
    }

    /// The daemon's order: `tree-changed` (a snapshot, taken before or after the move commits),
    /// then the echo. At no step does the tab show back in its old pane or in no pane.
    @Test(arguments: [false, true])
    func theTabNeverShowsBackOrEmptyWhileTheDaemonCatchesUp(snapshotHasTheMove: Bool) throws {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(try #require(store.workspaceMoveIntent(surface: Self.moved, into: 3)), transaction: transaction)

        store.apply(snapshot: Self.tree(movedInto: snapshotHasTheMove ? Self.landing : nil))
        #expect(Self.shown(store).pane == Self.landing)
        #expect(Self.shown(store).listed == 1)

        _ = store.apply(.tabChanged(TabDelta(workspace: 3, screen: 301, pane: Self.landing, surface: Self.moved, index: 1,
                                             entity: TabSnapshot(surface: Self.moved, terminalID: "70", kind: .pty, title: "vim"),
                                             clientTransactionID: transaction)))
        #expect(Self.shown(store).pane == Self.landing)
        #expect(Self.shown(store).listed == 1)
        #expect(store.pendingIntents.isEmpty)
    }

    @Test func aRefusedMoveGoesBackToItsPlaceExactly() throws {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(try #require(store.workspaceMoveIntent(surface: Self.moved, into: 3)), transaction: transaction)
        store.rejectIntent(transaction)

        #expect(store.pane(Self.source)?.tabs.map(\.surface) == [1, Self.moved])
        #expect(store.pane(Self.landing)?.tabs.map(\.surface) == [3])
        #expect(store.pendingIntents.isEmpty)
    }

    @Test func noIntentWhenTheStoreCannotKnowThePlace() {
        let store = Self.store()
        let empty = WorkspaceSnapshot(id: 5, key: nil, name: "empty")
        var tree = Self.tree()
        tree.workspaces.append(empty)
        store.apply(snapshot: tree)
        #expect(store.workspaceMoveIntent(surface: Self.moved, into: 5) == nil)
        #expect(store.workspaceMoveIntent(surface: Self.moved, into: 1) == nil)
        #expect(store.workspaceMoveIntent(surface: Self.moved, into: 99) == nil)
    }
}
