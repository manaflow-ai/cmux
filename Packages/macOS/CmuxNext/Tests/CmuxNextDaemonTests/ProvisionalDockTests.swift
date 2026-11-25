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

    /// Leo 2026-11-03, on "This pane is still opening; try again in a moment.": "this is extremely bad. i should be
    /// able to just close immedeiately." (#33829). A close of the dock's fresh-tab stand-in before the daemon confirms
    /// takes it out at once (the chat still docks), and the daemon's fresh tab, when it lands, is hidden and closed:
    /// never shown, not even after the dock settles, until its close commits.
    @Test func closingTheFreshTabsStandInClosesItAtOnceAndItsDaemonTabNeverShows() throws {
        let store = Self.store()
        var closed: [SurfaceID] = []
        store.creations.onClose { _, surface in closed.append(surface) }
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let terminal = TerminalID.generate()
        let standIn = ProvisionalTab().terminal(terminal, cwd: nil)
        let standInID = try #require(standIn.tabResourceID?.rawValue)
        let transaction = ClientTransactionID.generate()
        store.intend(.dockTab(surface: Self.chat, pane: Self.pane, provisional: provisional, dock: Self.dock, standIn: standIn),
                     transaction: transaction)
        #expect(store.panesByHandle[Self.pane]?.tabs.map(\.surface) == [standIn.surface])

        // The close takes effect on the click: the stand-in leaves, the chat stays docked, nothing is sent yet.
        #expect(store.creations.isPending(tab: standInID), "the dock's stand-in is not a pending creation's tab")
        #expect(store.creations.cancel(tab: standInID), "the close of the dock's stand-in was not taken")
        #expect(store.tabsBySurface[standIn.surface] == nil, "the stand-in still shows after its close")
        #expect(store.panesByHandle[Self.pane]?.tabs.isEmpty == true)
        #expect(store.panesByHandle[provisional.handle]?.tabs.map(\.surface) == [Self.chat], "the close undid the dock")
        #expect(!store.creations.isPending(tab: standInID))
        #expect(closed.isEmpty, "a close was sent before the daemon named the fresh tab")

        // The daemon's dock and fresh tab land (the fresh tab runs the stand-in's terminal): it is hidden and closed.
        let fresh = SurfaceID(rawValue: 8), docked = PaneID(rawValue: 9)
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.docked(docked, provisional, fresh: fresh, terminal: terminal)]))
        #expect(store.tabsBySurface[fresh] == nil, "the daemon's fresh tab showed after its stand-in was closed")
        #expect(store.panesByHandle[Self.pane]?.tabs.isEmpty == true)
        #expect(store.panesByHandle[docked]?.tabs.map(\.surface) == [Self.chat])
        #expect(closed == [fresh], "the daemon's fresh tab was not closed: \(closed)")

        // The move's reply settles the dock: the fresh tab still stays out while the daemon holds it.
        store.noteSettled(transaction, at: 0)
        #expect(store.tabsBySurface[fresh] == nil, "the fresh tab came back when the dock settled")
        #expect(store.pendingIntents.count == 1, "the dock left before its fresh tab's close committed")

        // The close commits: the intent leaves, and nothing comes back.
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [Self.docked(docked, provisional, fresh: nil, terminal: terminal)]))
        #expect(store.pendingIntents.isEmpty)
        #expect(store.tabsBySurface[fresh] == nil && store.tabsBySurface[standIn.surface] == nil)
        #expect(store.panesByHandle[docked]?.tabs.map(\.surface) == [Self.chat])
        #expect(closed == [fresh], "the fresh tab's close was sent again: \(closed)")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// Review of #34367 (P1): the daemon's dock pane and the layout that places it can come, and the move settle, before
    /// its fresh tab. The closed stand-in's intent waits for that tab, so a fresh tab that lands later is still hidden
    /// and closed, never shown.
    @Test func aFreshTabThatLandsAfterTheDockSettledStaysClosed() throws {
        let store = Self.store()
        var closed: [SurfaceID] = []
        store.creations.onClose { _, surface in closed.append(surface) }
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let terminal = TerminalID.generate()
        let standIn = ProvisionalTab().terminal(terminal, cwd: nil)
        let transaction = ClientTransactionID.generate()
        store.intend(.dockTab(surface: Self.chat, pane: Self.pane, provisional: provisional, dock: Self.dock, standIn: standIn),
                     transaction: transaction)
        #expect(store.creations.cancel(tab: try #require(standIn.tabResourceID?.rawValue)))
        let docked = PaneID(rawValue: 9), fresh = SurfaceID(rawValue: 8)
        let column = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 0.5, layout: .leaf(docked), dock: Self.dock)
        let rest = ColumnSnapshot(id: ColumnID(rawValue: 11), width: 1, layout: .leaf(Self.pane))
        _ = store.apply(batch: [
            DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
                workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: docked, index: 0,
                entity: PaneSnapshot(id: docked, resourceID: ResourceID(rawValue: provisional.paneID), tabs: []),
                clientTransactionID: nil))),
            DaemonEventEnvelope(sequence: 2, event: .layoutChanged(screen: ScreenID(rawValue: 2), layout: ScreenLayoutDelta(
                activePane: Self.pane, layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(docked), b: .leaf(Self.pane)),
                columns: [column, rest]), transaction: nil)),
        ])
        store.noteSettled(transaction, at: 2)
        #expect(store.pendingIntents.count == 1, "the closed stand-in's dock left before its fresh tab came")
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: Self.pane, surface: fresh, index: nil,
            entity: TabSnapshot(surface: fresh, terminalID: terminal, kind: .pty))))])
        #expect(store.tabsBySurface[fresh] == nil, "the fresh tab that landed after the dock settled showed")
        #expect(closed == [fresh], "the late fresh tab was not closed: \(closed)")
    }

    /// The same close when the daemon refuses the move: the dock goes, the chat is back in its pane, and no stand-in
    /// or fresh tab shows.
    @Test func aRefusedDockAfterItsStandInClosedShowsTheChatOnly() throws {
        let store = Self.store()
        store.creations.onClose { _, _ in }
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let standIn = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
        let transaction = ClientTransactionID.generate()
        store.intend(.dockTab(surface: Self.chat, pane: Self.pane, provisional: provisional, dock: Self.dock, standIn: standIn),
                     transaction: transaction)
        #expect(store.creations.cancel(tab: try #require(standIn.tabResourceID?.rawValue)))
        store.rejectIntent(transaction)
        #expect(store.pendingIntents.isEmpty)
        #expect(store.panesByHandle[Self.pane]?.tabs.map(\.surface) == [Self.chat])
        #expect(store.tabsBySurface[standIn.surface] == nil)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// Close Pane on the dock's stand-in pane before the daemon confirms: the pane (and the chat in it) leaves the
    /// records in the close's turn, the daemon's dock pane that takes it over never shows, and the close's intent
    /// leaves once the daemon's records drop that pane. Before, the close named the stand-in and was refused with
    /// "This pane is still opening; try again in a moment." (Leo 2026-11-03: "i should be able to just close immedeiately").
    @Test func closingTheDocksStandInPaneTakesItOutAtOnceAndItsDaemonPaneNeverShows() async throws {
        let store = Self.store()
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let terminal = TerminalID.generate()
        let standIn = ProvisionalTab().terminal(terminal, cwd: nil)
        let dockTransaction = ClientTransactionID.generate()
        store.intend(.dockTab(surface: Self.chat, pane: Self.pane, provisional: provisional, dock: Self.dock, standIn: standIn),
                     transaction: dockTransaction)
        #expect(store.panesByHandle[provisional.handle] != nil)

        let closing = try #require(store.intendStandInPaneClose(provisional.handle), "no close intent for a stand-in pane")
        let screen = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(store.panesByHandle[provisional.handle] == nil, "the stand-in pane still shows after its close")
        #expect(screen.panes.map(\.handle) == [Self.pane])
        #expect(screen.layout == .leaf(Self.pane))
        #expect(screen.columns.map(\.layout.paneIDs).allSatisfy { !$0.contains(provisional.handle) }, "the dock column stayed")
        #expect(store.tabsBySurface[Self.chat] == nil, "the closed pane's chat still shows")
        #expect(store.intendStandInPaneClose(Self.pane) == nil, "a daemon pane got a stand-in close intent")

        // The daemon's dock lands under the stand-in's public pane id: it stays out.
        let fresh = SurfaceID(rawValue: 8), docked = PaneID(rawValue: 9)
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.docked(docked, provisional, fresh: fresh, terminal: terminal)]))
        #expect(store.panesByHandle[docked] == nil, "the daemon's dock pane showed after its stand-in was closed")
        #expect(store.workspace(id: Self.key.rawValue)?.screens.first?.panes.map(\.handle) == [Self.pane])
        #expect(store.tabsBySurface[Self.chat] == nil)

        // Both replies come; the close still waits for the records to drop the daemon's pane. The close's own wait
        // for its daemon pane finds the hidden one, after the dock settled too (review of #34367, P1: it threw
        // PendingPaneNotCreated, and the refused close brought the pane back without sending `close-pane`).
        #expect(try await store.daemonTarget(provisional.handle) == docked)
        store.noteSettled(dockTransaction, at: 0)
        #expect(try await store.daemonTarget(provisional.handle) == docked, "the close lost its daemon pane once the dock settled")
        store.noteSettled(closing, at: 0)
        #expect(store.panesByHandle[docked] == nil, "the daemon's dock pane came back when the replies settled")

        // The close commits: the pane is gone for good and the log is empty.
        let after = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: Self.pane, layout: .leaf(Self.pane),
                                     panes: [PaneSnapshot(id: Self.pane, tabs: [TabSnapshot(surface: fresh, terminalID: terminal, kind: .pty)])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [after]))
        #expect(store.pendingIntents.isEmpty, "\(store.pendingIntents)")
        #expect(store.panesByHandle[docked] == nil && store.panesByHandle[provisional.handle] == nil)
        #expect(store.panesByHandle[Self.pane]?.tabs.map(\.surface) == [fresh])
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// The daemon's tree after the dock: the chat in dock pane `docked`, and the source pane with the fresh tab
    /// (`fresh`, running `terminal`) or none once its close committed.
    private static func docked(_ docked: PaneID, _ provisional: ProvisionalPane, fresh: SurfaceID?, terminal: TerminalID) -> WorkspaceSnapshot {
        let column = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 0.5, layout: .leaf(docked), dock: dock)
        let rest = ColumnSnapshot(id: ColumnID(rawValue: 11), width: 1, layout: .leaf(pane))
        let tabs = fresh.map { [TabSnapshot(surface: $0, terminalID: terminal, kind: .pty)] } ?? []
        return WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: key, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane,
                                     layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(docked), b: .leaf(pane)),
                                     columns: [column, rest],
                                     panes: [PaneSnapshot(id: docked, resourceID: ResourceID(rawValue: provisional.paneID),
                                                          tabs: [TabSnapshot(surface: chat)]),
                                             PaneSnapshot(id: pane, tabs: tabs)])])
    }
}
