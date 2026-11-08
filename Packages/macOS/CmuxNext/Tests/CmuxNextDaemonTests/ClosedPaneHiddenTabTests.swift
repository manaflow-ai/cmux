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
}
