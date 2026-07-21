#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceListScrollUpdateTests {
    @Test func workspaceTableUsesNativeSoftTopScrollEdgeEffect() {
        guard #available(iOS 26.0, *) else { return }

        let tableView = makeTableView()

        #expect(tableView.topEdgeEffect.style == .soft)
    }

    @Test func coordinatorLeavesPanLifecycleToUIKit() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = makeTableView()

        coordinator.attach(to: tableView)

        #expect(
            !coordinator.responds(to: NSSelectorFromString("scrollPanGestureStateChanged:")),
            "UITableView must own pan interruption and deceleration without a coordinator target."
        )
    }

    @Test func structuralUpdateAppliesThroughNativeDataSource() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = makeTableView()
        coordinator.attach(to: tableView)

        coordinator.update(
            configuration: configuration(
                workspaceIDs: ["workspace-1", "workspace-2", "workspace-3"]
            ),
            in: tableView
        )

        #expect(tableView.numberOfRows(inSection: 0) == 3)
    }

    @Test func rebindingUsesLatestNativeSnapshot() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let firstTable = makeTableView()
        coordinator.attach(to: firstTable)

        coordinator.update(
            configuration: configuration(workspaceIDs: ["workspace-1", "workspace-2"]),
            in: firstTable
        )

        let replacementTable = makeTableView()
        coordinator.attach(to: replacementTable)

        #expect(replacementTable.numberOfRows(inSection: 0) == 2)
    }

    private func makeTableView() -> WorkspaceListUITableView {
        WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
    }

    private func configuration(workspaceIDs: [String]) -> WorkspaceListTable {
        let workspaces = workspaceIDs.map { rawID in
            MobileWorkspacePreview(
                id: .init(rawValue: rawID),
                name: rawID,
                terminals: []
            )
        }
        return WorkspaceListTable(
            items: workspaces.map { .workspace($0.id, indented: false) },
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            groupsByID: [:],
            groupHasUnreadByID: [:],
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 2,
            unreadIndicatorLeftShift: 0,
            profilePictureLeftShift: 0,
            profilePictureSize: 32,
            connectionStatus: .connected,
            connectionRequiresReauth: false,
            connectionRecoveryFailed: false,
            isRecoveringConnection: false,
            connectionError: nil,
            host: "Test Mac",
            isInitialConnectionLoading: false,
            initialConnectionTitle: nil,
            initialConnectionDescription: nil,
            enablesReorder: false,
            moveRows: nil,
            selectWorkspace: { _ in },
            requestWorkspaceClose: nil,
            closeWorkspace: nil,
            setUnread: nil,
            setPinned: nil,
            renameRequest: nil,
            createWorkspaceInGroup: nil,
            renameWorkspaceGroup: nil,
            setGroupPinned: nil,
            ungroupWorkspaceGroup: nil,
            deleteWorkspaceGroup: nil,
            toggleGroupCollapsed: nil,
            showAll: {},
            retryConnectionRecovery: nil,
            signOut: nil,
            retryInitialConnection: nil,
            showAddDevice: nil,
            reconnect: nil,
            refresh: nil
        )
    }
}
#endif
