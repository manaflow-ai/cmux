import Foundation
import Testing
@testable import CmuxNextDaemon

/// Split Browser Right/Down (`BrowserHandlers.splitBrowser`) shows its new pane in the key's turn: a
/// split intent whose provisional pane holds a browser stand-in. The daemon makes the tab in the
/// split's target pane (`new-frontend-browser-tab`, no transaction) and then moves it to a split of
/// its own (`move-tab-to-split`, which mints its own pane id), so neither names the split's public
/// ids. The tab stays out of sight while it is in the target pane, and the daemon's pane takes the
/// provisional pane's place in the apply that places it: one new pane all along, never two.
@MainActor
struct BrowserSplitStandInTests {
    private static let source = PaneID(rawValue: 3)
    private static let moved = PaneID(rawValue: 9)
    private static let daemonTab = SurfaceID(rawValue: 7)
    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")

    private static func tree(_ panes: [PaneSnapshot], layout: LayoutNode, revision: UInt64) -> DaemonTree {
        DaemonTree(workspaceRevision: revision, workspaces: [WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: source, layout: layout, panes: panes)])])
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree([PaneSnapshot(id: source, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])],
                                   layout: .leaf(source), revision: 1))
        return store
    }

    private static func browser(_ surface: SurfaceID) -> TabSnapshot {
        TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: "tab_\(surface.rawValue)"), kind: .browser,
                    url: "https://example.com/", browserRenderer: "frontend", browserEngine: "cef")
    }

    /// The stand-in's record, as `ProvisionalTab.browser(url:engine:profile:)` makes it.
    private static func standIn(_ provisional: ProvisionalTab) -> TabSnapshot {
        TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id), kind: .browser,
                    url: "https://example.com/", browserRenderer: "frontend", browserEngine: "cef")
    }

    /// The daemon's raw `tab-added` of the open's tab in the split's target pane (no transaction).
    private static func openedInSource(sequence: UInt64) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: source, surface: daemonTab,
            index: 1, entity: browser(daemonTab), clientTransactionID: nil)))
    }

    /// The records after `move-tab-to-split`: the tab alone in the daemon's new pane, which the layout places.
    private static func movedToItsOwnPane() -> DaemonTree {
        tree([PaneSnapshot(id: source, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))]), PaneSnapshot(id: moved, tabs: [browser(daemonTab)])],
             layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(source), b: .leaf(moved)), revision: 2)
    }

    private static func panes(_ store: DaemonStore) throws -> [PaneModel] {
        try #require(store.workspace(id: baseKey.rawValue)?.screens.first).panes
    }

    private static func split(_ store: DaemonStore) -> (ProvisionalTab, ProvisionalPane, ClientTransactionID) {
        let tab = ProvisionalTab(), transaction = ClientTransactionID.generate()
        let provisional = ProvisionalPane(holding: standIn(tab))
        store.intend(.splitPane(pane: source, direction: .right, ratio: 0.5, provisional: provisional), transaction: transaction)
        return (tab, provisional, transaction)
    }

    @Test func theStandInPaneShowsInTheIntentsTurn() throws {
        let store = Self.store()
        let (tab, provisional, _) = Self.split(store)
        let panes = try Self.panes(store)
        #expect(panes.map(\.handle) == [Self.source, provisional.handle])
        #expect(panes.last?.tabs.map(\.surface) == [tab.surface])
    }

    /// The open's tab lands in the target pane first: it stays out of sight there, the stand-in pane showing.
    @Test func theDaemonsTabInTheTargetPaneStaysHiddenBehindTheStandInPane() throws {
        let store = Self.store()
        let (tab, provisional, _) = Self.split(store)
        _ = store.apply(batch: [Self.openedInSource(sequence: 1)])
        let panes = try Self.panes(store)
        #expect(panes.map(\.handle) == [Self.source, provisional.handle])
        #expect(panes.first?.tabs.map(\.surface) == [SurfaceID(rawValue: 4)], "the split's tab showed in its target pane")
        #expect(panes.last?.tabs.map(\.surface) == [tab.surface])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The move places the tab in the daemon's own pane: that pane replaces the provisional one in
    /// the same apply (never both, never an empty pane beside it), and the intent then settles.
    @Test func theDaemonsPaneTakesTheStandInPanesPlaceInOneApply() throws {
        let store = Self.store()
        let (_, provisional, transaction) = Self.split(store)
        _ = store.apply(batch: [Self.openedInSource(sequence: 1)])
        store.apply(snapshot: Self.movedToItsOwnPane())
        let panes = try Self.panes(store)
        #expect(panes.map(\.handle) == [Self.source, Self.moved], "not one new pane: \(panes.map(\.handle))")
        #expect(panes.last?.tabs.map(\.surface) == [Self.daemonTab])
        #expect(!panes.contains { $0.handle == provisional.handle })
        store.noteSettled(transaction, at: 0)
        #expect(store.pendingIntents.isEmpty, "the split stayed in the log after the daemon's pane took its place")
        #expect(try Self.panes(store).map(\.handle) == [Self.source, Self.moved])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The open's reply names the tab (``ProvisionalTab/held(_:surface:in:)``) when no raw `tab-added`
    /// was guessed for it (the records got it some other way): it goes out of sight all the same.
    @Test func theOpensReplyHidesATabTheRecordsAlreadyShow() throws {
        let store = Self.store()
        let (tab, provisional, _) = Self.split(store)
        let transaction = try #require(store.pendingIntents.first?.transaction)
        store.apply(snapshot: Self.tree([PaneSnapshot(id: Self.source, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4)), Self.browser(Self.daemonTab)])],
                                        layout: .leaf(Self.source), revision: 2))
        #expect(try Self.panes(store).first?.tabs.map(\.surface) == [SurfaceID(rawValue: 4), Self.daemonTab])
        ProvisionalTab.held(transaction, surface: Self.daemonTab, in: store)
        let panes = try Self.panes(store)
        #expect(panes.map(\.handle) == [Self.source, provisional.handle])
        #expect(panes.first?.tabs.map(\.surface) == [SurfaceID(rawValue: 4)])
        #expect(panes.last?.tabs.map(\.surface) == [tab.surface])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A refused move takes the provisional pane back; the open's tab shows where the daemon left it.
    @Test func aRefusedMoveShowsTheTabInItsTargetPane() throws {
        let store = Self.store()
        let (_, _, transaction) = Self.split(store)
        _ = store.apply(batch: [Self.openedInSource(sequence: 1)])
        store.rejectIntent(transaction)
        let panes = try Self.panes(store)
        #expect(panes.map(\.handle) == [Self.source])
        #expect(panes.first?.tabs.map(\.surface) == [SurfaceID(rawValue: 4), Self.daemonTab])
        #expect(store.mirrorViolations.isEmpty)
    }
}
