import Foundation
import Testing
@testable import CmuxNextDaemon

/// A lone chat docked by a new tab from its pane (`move-tab-to-column {dock, respawn, pane_id}`,
/// `tab-column-client-pane-v1`): in the input's turn the chat shows in a stand-in left dock and its
/// pane shows the fresh tab's stand-in, before the daemon answers (Leo: "it's so slow to open and
/// close ... we need to be at least as fast" as Claude and Codex).
@MainActor
struct ProvisionalDockTests {
    private static let pane = PaneID(rawValue: 3)
    private static let chat = SurfaceID(rawValue: 4)
    private static let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000003")
    private static let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat)

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let tree = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: key, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: chat)])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [tree]))
        return store
    }

    @Test func theDockAndTheFreshTabShowInTheInputsTurnAndARefusalTakesThemOut() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let standIn = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
        let transaction = ClientTransactionID.generate()
        store.intend(.dockTab(surface: Self.chat, pane: Self.pane, provisional: provisional, dock: Self.dock, standIn: standIn),
                     transaction: transaction)
        let screen = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(screen.columns.map(\.layout.paneIDs) == [[provisional.handle], [Self.pane]])
        #expect(screen.columns.first?.dock == Self.dock)
        #expect(screen.columns.first?.width == 0.5)
        #expect(screen.panes.map(\.handle) == [provisional.handle, Self.pane])
        #expect(store.panesByHandle[provisional.handle]?.tabs.map(\.surface) == [Self.chat], "the chat did not move into the dock")
        #expect(store.panesByHandle[Self.pane]?.tabs.map(\.surface) == [standIn.surface], "the pane shows no fresh tab")
        store.rejectIntent(transaction)
        let after = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(after.columns.isEmpty && after.layout == .leaf(Self.pane))
        #expect(after.panes.map(\.handle) == [Self.pane])
        #expect(store.panesByHandle[Self.pane]?.tabs.map(\.surface) == [Self.chat])
        #expect(store.tabsBySurface[standIn.surface] == nil)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The daemon's fresh tab replaces the stand-in when it arrives, and its pane under the minted
    /// id takes the stand-in dock's model over in place, so the chat's pane object never changes.
    @Test func theDaemonsPaneTakesTheDockOverInPlace() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let standIn = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
        let transaction = ClientTransactionID.generate()
        store.intend(.dockTab(surface: Self.chat, pane: Self.pane, provisional: provisional, dock: Self.dock, standIn: standIn),
                     transaction: transaction)
        let shown = try #require(store.panesByHandle[provisional.handle])
        let fresh = SurfaceID(rawValue: 8), docked = PaneID(rawValue: 9)
        // `pane-added` comes before the layout that places the pane: the dock places the daemon's pane.
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: docked, index: 0,
            entity: PaneSnapshot(id: docked, resourceID: ResourceID(rawValue: provisional.paneID), tabs: []),
            clientTransactionID: nil)))])
        #expect(store.panesByHandle[docked] === shown, "the daemon's dock pane is a new model")
        #expect(store.panesByHandle[docked]?.tabs.map(\.surface) == [Self.chat])
        let between = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(between.columns.map(\.layout.paneIDs) == [[docked], [Self.pane]])
        #expect(store.pendingIntents.count == 1)
        let column = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 0.5, layout: .leaf(docked), dock: Self.dock)
        let rest = ColumnSnapshot(id: ColumnID(rawValue: 11), width: 1, layout: .leaf(Self.pane))
        let tree = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: Self.pane,
                                     layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(docked), b: .leaf(Self.pane)),
                                     columns: [column, rest],
                                     panes: [PaneSnapshot(id: docked, resourceID: ResourceID(rawValue: provisional.paneID),
                                                          tabs: [TabSnapshot(surface: Self.chat)]),
                                             PaneSnapshot(id: Self.pane, tabs: [TabSnapshot(surface: fresh)])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [tree]))
        store.noteSettled(transaction, at: 0)
        #expect(store.pendingIntents.isEmpty, "the dock still waits after the daemon placed its pane")
        let screen = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(screen.columns.map(\.layout.paneIDs) == [[docked], [Self.pane]])
        #expect(store.panesByHandle[docked]?.tabs.map(\.surface) == [Self.chat])
        #expect(store.panesByHandle[Self.pane]?.tabs.map(\.surface) == [fresh])
        #expect(store.tabsBySurface[standIn.surface] == nil)
        #expect(store.mirrorViolations.isEmpty)
    }
}
