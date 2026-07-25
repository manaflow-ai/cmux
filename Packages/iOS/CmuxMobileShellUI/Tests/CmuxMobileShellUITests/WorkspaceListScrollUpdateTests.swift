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

    @Test func coordinatorKeepsWorkspaceRowSwipeAndContextMenuActionsAvailable() {
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: true,
            supportsReadStateActions: true,
            supportsCloseActions: true,
            supportsMoveActions: true,
            supportsGroupActions: true,
            supportsGroupCreate: true
        )
        let initial = configuration(
            workspaceIDs: ["workspace-1"],
            actionCapabilities: capabilities,
            requestWorkspaceClose: { _ in },
            closeWorkspace: { _ in },
            setUnread: { _, _ in },
            setPinned: { _, _ in },
            renameRequest: { _ in },
            customizeRequest: { _ in }
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = makeTableView()
        coordinator.attach(to: tableView)
        let indexPath = IndexPath(row: 0, section: 0)

        let dataSourceAllowsEditing =
            tableView.dataSource?.tableView?(tableView, canEditRowAt: indexPath) ?? true
        #expect(dataSourceAllowsEditing)
        #expect(
            coordinator.tableView(
                tableView,
                leadingSwipeActionsConfigurationForRowAt: indexPath
            ) != nil
        )
        #expect(
            coordinator.tableView(
                tableView,
                trailingSwipeActionsConfigurationForRowAt: indexPath
            ) != nil
        )
        #expect(
            coordinator.tableView(
                tableView,
                contextMenuConfigurationForRowAt: indexPath,
                point: .zero
            ) != nil
        )
    }

    private func makeTableView() -> WorkspaceListUITableView {
        WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
    }

    private func configuration(
        workspaceIDs: [String],
        actionCapabilities: MobileWorkspaceActionCapabilities = .none,
        requestWorkspaceClose: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        renameRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        customizeRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil
    ) -> WorkspaceListTable {
        let workspaces = workspaceIDs.map { rawID in
            var workspace = MobileWorkspacePreview(
                id: .init(rawValue: rawID),
                name: rawID,
                terminals: []
            )
            workspace.actionCapabilities = actionCapabilities
            return workspace
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
            requestWorkspaceClose: requestWorkspaceClose,
            closeWorkspace: closeWorkspace,
            setUnread: setUnread,
            setPinned: setPinned,
            renameRequest: renameRequest,
            customizeRequest: customizeRequest,
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
