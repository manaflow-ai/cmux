@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// Close Pane on a stand-in pane still opening (#34367) leaves the records in the click's turn and its close waits for
/// the daemon's pane. When the close cannot run at all (this daemon has no connection), no close intent may stay
/// behind: it hid the pane for good, since nothing settled or rejected it (review of #34367, #34448).
@MainActor @Suite(.serialized) struct StandInPaneCloseTests {
    @MainActor final class Outcomes { var failed: [Bool] = [] }

    private static let pane = PaneID(rawValue: 3)
    private static let chat = SurfaceID(rawValue: 4)
    private static let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000034")

    @Test func aStandInPaneCloseOnANotConnectedDaemonLeavesNoIntentBehind() async throws {
        let daemon = DaemonService(machineID: "test:not-connected")
        let store = daemon.store
        let tree = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: Self.pane, layout: .leaf(Self.pane),
                                     panes: [PaneSnapshot(id: Self.pane, tabs: [TabSnapshot(surface: Self.chat)])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [tree]))
        let provisional = ProvisionalPane(columnWidth: 0.5, left: true)
        let standIn = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
        store.intend(.dockTab(surface: Self.chat, pane: Self.pane, provisional: provisional,
                              dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat), standIn: standIn),
                     transaction: ClientTransactionID.generate())
        #expect(store.pendingIntents.count == 1)

        let finished = Outcomes()
        daemon.closePane(provisional.handle) { failed in finished.failed.append(failed) }
        // The send's task runs and fails "not connected"; give it every turn it needs.
        for _ in 0..<50 { await Task.yield() }

        #expect(store.pendingIntents.count == 1, "a close intent stayed in the log: \(store.pendingIntents)")
        #expect(!store.pendingIntents.contains { if case .closeStandInPane = $0 { true } else { false } })
        #expect(store.panesByHandle[provisional.handle] != nil, "the pane is hidden though no close could be sent")
        #expect(finished.failed.isEmpty, "a close that never ran reported an outcome: \(finished.failed)")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }
}
