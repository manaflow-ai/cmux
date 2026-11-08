import Testing
@testable import CmuxNextDaemon

/// A pane's last tab closed (Cmd-W in a split): its close intent hides the tab in the key's turn, and the pane leaves on
/// one motion. The daemon then closes the tab and its pane. Each daemon apply lifts the overlay, so the tab goes back into
/// its pane's record for the apply; when the apply closes that pane first (`pane-closed`, then `tab-closed` names a pane
/// that is gone), the closed pane's record kept the tab, and its leaving pane showed the closed tab again until its
/// landing (CLOSE VARIANTS 3, P0 late start Cost 2: revealed at 53-61 ms, concealed at 302 ms in the R3 and G4 profiles).
@MainActor
struct ClosedPaneHiddenTabTests {
    private static let kept = PaneID(rawValue: 3), closing = PaneID(rawValue: 13)
    private static let keptTab = SurfaceID(rawValue: 4), closedTab = SurfaceID(rawValue: 14)
    private static let workspace = WorkspaceHandle(rawValue: 1), screen = ScreenID(rawValue: 2)

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let workspace = WorkspaceSnapshot(
            id: workspace, key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: screen, active: true, activePane: closing,
                                     layout: .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(kept), b: .leaf(closing)),
                                     panes: [PaneSnapshot(id: kept, tabs: [TabSnapshot(surface: keptTab)]),
                                             PaneSnapshot(id: closing, tabs: [TabSnapshot(surface: closedTab)])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        return store
    }

    private static var paneClosed: DaemonEvent {
        .paneClosed(PaneDelta(workspace: workspace, screen: screen, pane: closing, index: nil,
                              entity: PaneSnapshot(id: closing, tabs: []), clientTransactionID: nil))
    }

    private static var tabClosed: DaemonEvent {
        .tabClosed(TabDelta(workspace: workspace, screen: screen, pane: closing, surface: closedTab, index: nil,
                            entity: TabSnapshot(surface: closedTab), clientTransactionID: nil))
    }

    /// The daemon's orders: the pane first (its last tab named after), the tab first, the pane alone, each in one batch
    /// and in two.
    @Test(arguments: [0, 1, 2, 3, 4])
    func theClosedPanesRecordNeverListsTheClosedTabAgain(order: Int) throws {
        let store = Self.store()
        let pane = try #require(store.pane(Self.closing))
        let close = try #require(store.intendClose([Self.closedTab]))
        try #require(pane.tabs.isEmpty, "the intent hid the tab in the key's turn")
        let batches: [[DaemonEvent]] = switch order {
        case 0: [[Self.paneClosed, Self.tabClosed]]
        case 1: [[Self.tabClosed, Self.paneClosed]]
        case 2: [[Self.paneClosed]]
        case 3: [[Self.paneClosed], [Self.tabClosed]]
        default: [[Self.tabClosed], [Self.paneClosed]]
        }
        var sequence: UInt64 = 0
        for batch in batches {
            _ = store.apply(batch: batch.map { event in sequence += 1; return DaemonEventEnvelope(sequence: sequence, event: event) })
            #expect(pane.tabs.isEmpty, "the closed pane's record lists the closed tab again (order \(order), after event \(sequence))")
            #expect(store.tab(surface: Self.closedTab) == nil)
        }
        store.noteSettled(close, at: sequence)
        #expect(pane.tabs.isEmpty, "the settled close showed the closed tab again (order \(order))")
        #expect(store.pendingIntents.isEmpty)
        #expect(store.pane(Self.kept)?.tabs.map(\.surface) == [Self.keptTab], "the other pane keeps its tab")
    }

    /// A refused close (the daemon kept the tab and its pane) still brings the tab back in place.
    @Test func aRefusedCloseStillBringsTheTabBack() throws {
        let store = Self.store()
        let pane = try #require(store.pane(Self.closing))
        let close = try #require(store.intendClose([Self.closedTab]))
        store.rejectIntent(close)
        #expect(pane.tabs.map(\.surface) == [Self.closedTab])
    }

    /// Review of #38302 (Medium): a refused close of a tab whose pane a pending stand-in pane close hides (the dock's
    /// daemon pane, closed while the dock's reply has not come) keeps its tab. The overlay's restore hides that pane
    /// again, so after the restore it looks gone like a pane the daemon closed; only a pane the confirmed records
    /// dropped may lose the closed tab. Before, the refused close took the tab out of the hidden pane's record, and the
    /// refused pane close then brought the pane back without its tab.
    @Test func aRefusedCloseUnderAPendingStandInPaneCloseKeepsItsTab() throws {
        let source = PaneID(rawValue: 3), docked = PaneID(rawValue: 9)
        let chat = SurfaceID(rawValue: 4), fresh = SurfaceID(rawValue: 8)
        let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000003")
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat)
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(
            id: Self.workspace, key: key, name: "1",
            screens: [ScreenSnapshot(id: Self.screen, active: true, activePane: source, layout: .leaf(source),
                                     panes: [PaneSnapshot(id: source, tabs: [TabSnapshot(surface: chat)])])])]))
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let standIn = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
        store.intend(.dockTab(surface: chat, pane: source, provisional: provisional, dock: dock, standIn: standIn),
                     transaction: ClientTransactionID.generate())
        // The daemon's dock lands before the dock's reply: its pane holds the chat in the confirmed records.
        let column = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 0.5, layout: .leaf(docked), dock: dock)
        let rest = ColumnSnapshot(id: ColumnID(rawValue: 11), width: 1, layout: .leaf(source))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [WorkspaceSnapshot(
            id: Self.workspace, key: key, name: "1",
            screens: [ScreenSnapshot(id: Self.screen, active: true, activePane: source,
                                     layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(docked), b: .leaf(source)),
                                     columns: [column, rest],
                                     panes: [PaneSnapshot(id: docked, resourceID: ResourceID(rawValue: provisional.paneID),
                                                          tabs: [TabSnapshot(surface: chat)]),
                                             PaneSnapshot(id: source, tabs: [TabSnapshot(surface: fresh)])])])]))
        let pane = try #require(store.panesByHandle[docked])
        try #require(pane.tabs.map(\.surface) == [chat], "the daemon's dock pane does not show the chat")
        let close = try #require(store.intendClose([chat]))
        let paneClose = try #require(store.intendStandInPaneClose(provisional.handle), "no close intent for the dock's stand-in")
        try #require(store.panesByHandle[docked] == nil, "the stand-in's close does not hide the daemon's dock pane")

        store.rejectIntent(close)
        #expect(pane.tabs.map(\.surface) == [chat], "the refused close took the tab out of the hidden pane's record")
        store.rejectIntent(paneClose)
        #expect(store.panesByHandle[docked]?.tabs.map(\.surface) == [chat], "the refused pane close brought the pane back without its tab")
        #expect(store.tab(surface: chat) != nil)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// The same refusal before the daemon's dock lands: the stand-in pane is a provisional record the confirmed records
    /// never held, so it is never a pane the daemon closed. Before, the lift found no confirmed pane for it, the refused
    /// close took the chat out of it, and the refused pane close could not undo the dock (the docked surface was missing).
    @Test func aRefusedCloseInAPendingStandInPaneKeepsItsTabBeforeTheDockLands() throws {
        let source = PaneID(rawValue: 3)
        let chat = SurfaceID(rawValue: 4)
        let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000003")
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat)
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(
            id: Self.workspace, key: key, name: "1",
            screens: [ScreenSnapshot(id: Self.screen, active: true, activePane: source, layout: .leaf(source),
                                     panes: [PaneSnapshot(id: source, tabs: [TabSnapshot(surface: chat)])])])]))
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let standIn = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
        store.intend(.dockTab(surface: chat, pane: source, provisional: provisional, dock: dock, standIn: standIn),
                     transaction: ClientTransactionID.generate())
        let pane = try #require(store.panesByHandle[provisional.handle], "the dock shows no stand-in pane")
        try #require(pane.tabs.map(\.surface) == [chat], "the stand-in pane does not show the chat")
        let close = try #require(store.intendClose([chat]))
        let paneClose = try #require(store.intendStandInPaneClose(provisional.handle), "no close intent for the dock's stand-in")
        try #require(store.panesByHandle[provisional.handle] == nil, "the stand-in's close does not hide the stand-in pane")

        store.rejectIntent(close)
        #expect(pane.tabs.map(\.surface) == [chat], "the refused close took the tab out of the hidden stand-in pane")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
        store.rejectIntent(paneClose)
        #expect(store.panesByHandle[provisional.handle]?.tabs.map(\.surface) == [chat],
                "the refused pane close brought the stand-in pane back without its tab")
        #expect(store.tab(surface: chat) != nil)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }
}
