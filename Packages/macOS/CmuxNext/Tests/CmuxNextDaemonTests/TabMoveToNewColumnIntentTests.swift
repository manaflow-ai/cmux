import Foundation
import Testing
@testable import CmuxNextDaemon

/// Move Tab to New Column as a store intent (`tab-column-client-keys-v1`): the moved tab shows in a new
/// column right of the anchor's column in the input's turn, under the client-minted pane id the daemon's pane
/// will carry; it stays through an older snapshot; a refusal puts the tab back in its pane at its place and
/// removes the column; the daemon's pane under the same public id replaces the stand-in. Before, the move sent
/// `move-tab-to-column` and showed nothing until the reply (sweep: tab.moveToNewColumn, macOS 27).
@MainActor
struct TabMoveToNewColumnIntentTests {
    private static let anchor = PaneID(rawValue: 3)
    private static let moved = SurfaceID(rawValue: 7)
    private static let kept = SurfaceID(rawValue: 4)

    /// Workspace 1, screen 2: pane 3 holds surfaces 4 and 7 (the moved one at index 1).
    private static func tree(withMoved: Bool = true) -> DaemonTree {
        let tabs = withMoved ? [TabSnapshot(surface: kept), TabSnapshot(surface: moved, terminalID: "70", kind: .pty, title: "vim")]
            : [TabSnapshot(surface: kept)]
        return DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: nil, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: anchor, layout: .leaf(anchor),
                                     panes: [PaneSnapshot(id: anchor, tabs: tabs)])])])
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree())
        return store
    }

    private static func intent(_ provisional: ProvisionalPane) -> Intent {
        .splitPane(pane: anchor, direction: .right, ratio: 0.5, provisional: provisional)
    }

    @Test func theTabShowsInANewColumnInTheInputsTurn() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(moving: Self.moved, columnWidth: 0.5, treeWidth: 0.5)
        store.intend(Self.intent(provisional), transaction: .generate())
        let screen = try #require(store.screen(ScreenID(rawValue: 2)))
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.anchor], [provisional.handle]])
        #expect(store.pane(Self.anchor)?.tabs.map(\.surface) == [Self.kept])
        #expect(store.pane(provisional.handle)?.tabs.map(\.surface) == [Self.moved])
        #expect(store.pane(provisional.handle)?.resourceID?.rawValue == provisional.paneID)
        #expect(store.pane(containing: Self.moved)?.handle == provisional.handle, "the index does not find the moved tab")
        #expect(store.mirrorViolations.isEmpty)
    }

    @Test func anOlderSnapshotKeepsTheMove() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(moving: Self.moved, columnWidth: 0.5, treeWidth: 0.5)
        store.intend(Self.intent(provisional), transaction: .generate())
        store.apply(snapshot: Self.tree())
        #expect(store.pane(Self.anchor)?.tabs.map(\.surface) == [Self.kept])
        #expect(store.pane(provisional.handle)?.tabs.map(\.surface) == [Self.moved])
        #expect(store.mirrorViolations.isEmpty)
    }

    @Test func aRefusalPutsTheTabBackAtItsPlace() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(moving: Self.moved, columnWidth: 0.5, treeWidth: 0.5)
        let transaction = ClientTransactionID.generate()
        store.intend(Self.intent(provisional), transaction: transaction)
        store.rejectIntent(transaction)
        let screen = try #require(store.screen(ScreenID(rawValue: 2)))
        #expect(screen.columns.isEmpty)
        #expect(screen.panes.map(\.handle) == [Self.anchor])
        #expect(store.pane(Self.anchor)?.tabs.map(\.surface) == [Self.kept, Self.moved])
        #expect(store.pane(containing: Self.moved)?.handle == Self.anchor)
        #expect(store.pendingIntents.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The daemon's answer: its pane under the client-minted public id holds the tab and a column places it.
    /// Once the records hold it the stand-in is gone and the tab is listed once.
    @Test func theDaemonsPaneUnderTheSamePublicIDReplacesTheStandIn() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(moving: Self.moved, columnWidth: 0.5, treeWidth: 0.5)
        let transaction = ClientTransactionID.generate()
        store.intend(Self.intent(provisional), transaction: transaction)
        let daemon = PaneID(rawValue: 9)
        var after = Self.tree(withMoved: false)
        after.workspaces[0].screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(Self.anchor), b: .leaf(daemon))
        after.workspaces[0].screens[0].columns = [ColumnSnapshot(id: ColumnID(rawValue: 20), width: 0.5, layout: .leaf(Self.anchor)),
                                                  ColumnSnapshot(id: ColumnID(rawValue: 21), width: 0.5, layout: .leaf(daemon))]
        after.workspaces[0].screens[0].panes.append(PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: provisional.paneID),
                                                                 tabs: [TabSnapshot(surface: Self.moved, terminalID: "70", kind: .pty, title: "vim")]))
        store.apply(snapshot: after)
        store.noteSettledAtNextSnapshot(transaction)
        store.apply(snapshot: after)
        let screen = try #require(store.screen(ScreenID(rawValue: 2)))
        #expect(screen.panes.map(\.handle) == [Self.anchor, daemon])
        let listed = screen.panes.flatMap(\.tabs).filter { $0.surface == Self.moved }.count
        #expect(listed == 1)
        #expect(store.pendingIntents.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A pane's only tab: the daemon closes the emptied pane as it moves the tab, and so does the stand-in, in the
    /// same turn (here the pane is the anchor itself: its column goes, the new one stays); a refusal brings both back.
    @Test func aPanesOnlyTabClosesItsPaneInTheSameTurnAndARefusalBringsItBack() throws {
        let store = DaemonStore()
        var tree = Self.tree()
        tree.workspaces[0].screens[0].panes[0].tabs = [TabSnapshot(surface: Self.moved)]
        store.apply(snapshot: tree)
        let provisional = ProvisionalPane(moving: Self.moved, columnWidth: 0.5, treeWidth: 0.5)
        let transaction = ClientTransactionID.generate()
        store.intend(Self.intent(provisional), transaction: transaction)
        let screen = try #require(store.screen(ScreenID(rawValue: 2)))
        #expect(screen.panes.map(\.handle) == [provisional.handle], "the emptied pane still shows")
        #expect(screen.layout.paneIDs == [provisional.handle])
        #expect(screen.columns.map(\.layout.paneIDs) == [[provisional.handle]])
        #expect(store.pane(provisional.handle)?.tabs.map(\.surface) == [Self.moved])
        #expect(store.mirrorViolations.isEmpty)

        store.rejectIntent(transaction)
        let back = try #require(store.screen(ScreenID(rawValue: 2)))
        #expect(back.panes.map(\.handle) == [Self.anchor])
        #expect(back.layout == .leaf(Self.anchor))
        #expect(back.columns.isEmpty)
        #expect(store.pane(Self.anchor)?.tabs.map(\.surface) == [Self.moved])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A tab whose pane keeps another, moved into a new column after a different anchor pane: only the tab moves.
    @Test func aTabFromAnotherPaneMovesAloneAndItsPaneStays() throws {
        let store = DaemonStore()
        var tree = Self.tree()
        let other = PaneID(rawValue: 5)
        tree.workspaces[0].screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(Self.anchor), b: .leaf(other))
        tree.workspaces[0].screens[0].panes.append(PaneSnapshot(id: other, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 8))]))
        store.apply(snapshot: tree)
        let provisional = ProvisionalPane(moving: Self.moved, columnWidth: 0.5, treeWidth: 0.5)
        store.intend(.splitPane(pane: other, direction: .right, ratio: 0.5, provisional: provisional), transaction: .generate())
        let screen = try #require(store.screen(ScreenID(rawValue: 2)))
        #expect(screen.panes.map(\.handle) == [Self.anchor, other, provisional.handle])
        #expect(store.pane(Self.anchor)?.tabs.map(\.surface) == [Self.kept])
        #expect(store.pane(provisional.handle)?.tabs.map(\.surface) == [Self.moved])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// Closing the moved tab or its stand-in column while the move is pending is a plain close of the person's
    /// tab, never a cancelled create (review of pl-instant-tabcolumn, PL-motion-core): the stand-in holds an
    /// existing daemon tab, so a cancel would hide the column and close that surface as an unwanted create.
    @Test func aCloseDuringThePendingMoveIsNoCancelledCreate() throws {
        let store = Self.store()
        var closed: [SurfaceID] = []
        store.creations.onClose { _, surface in closed.append(surface) }
        let provisional = ProvisionalPane(moving: Self.moved, columnWidth: 0.5, treeWidth: 0.5)
        store.intend(Self.intent(provisional), transaction: .generate())
        let movedTab = try #require(store.pane(provisional.handle)?.tabs.first?.id)
        #expect(!store.creations.isPending(tab: movedTab))
        #expect(!store.creations.cancel(tab: movedTab), "closing the moved tab cancelled a create")
        #expect(!store.creations.cancel(splitShowing: movedTab), "closing the stand-in by its tab cancelled a create")
        #expect(!store.creations.cancel(pane: provisional.handle), "closing the stand-in column cancelled a create")
        #expect(closed.isEmpty, "a cancelled-create close went out for the person's own tab: \(closed)")
        #expect(store.pane(provisional.handle)?.tabs.map(\.surface) == [Self.moved], "the stand-in left without a close")
        #expect(store.mirrorViolations.isEmpty)
    }
}

/// The request carries the stand-in's client keys as `pane_id` and `split_id` (`tab-column-client-keys-v1`),
/// and only when given: an older daemon gets the request it knows.
struct MoveTabToColumnClientKeysWireTests {
    private func fields(_ request: MoveTabToColumnRequest) throws -> [String: JSONValue] {
        let line = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: line) else { return [:] }
        return fields
    }

    @Test func theClientKeysGoOutSnakeCasedAndOnlyWhenGiven() throws {
        let keyed = try fields(MoveTabToColumnRequest(surface: SurfaceID(rawValue: 7), target: .pane(PaneID(rawValue: 3)), width: 0.5,
                                                      paneID: "pane_abc", splitID: "split_def"))
        #expect(keyed["pane_id"] == .string("pane_abc"))
        #expect(keyed["split_id"] == .string("split_def"))
        let plain = try fields(MoveTabToColumnRequest(surface: SurfaceID(rawValue: 7), target: .pane(PaneID(rawValue: 3)), width: 0.5))
        #expect(plain["pane_id"] == nil && plain["split_id"] == nil)
    }
}
