#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI
import UIKit

/// UIKit-owned workspace list with exact, non-estimated row heights.
@MainActor
struct WorkspaceListTable: UIViewControllerRepresentable {
    #if DEBUG
    @Environment(\.releaseGateUIProbe) var releaseGateUIProbe
    @Environment(\.releaseGateSnapshotter) var releaseGateSnapshotter
    #endif
    let items: [WorkspaceListTableItem]
    let workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    let groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    let groupUnreadByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceUnreadState]
    let filter: MobileWorkspaceListFilter
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let navigationStyle: WorkspaceNavigationStyle
    let wrapWorkspaceTitles: Bool
    let previewLineLimit: Int
    let unreadIndicatorLeftShift: Double
    let unreadBadgeDiameter: Double
    let connectionStatus: MobileMacConnectionStatus
    var workspaceOwnerID: String? = nil
    var workspaceOwnerInstanceTag: String? = nil
    var showsWorkspaceEmptyState = true
    /// Whether the connected Mac advertises `workspace.changes.v1`.
    let workspaceChangesCapable: Bool
    /// Changes chips keyed by the workspace's RPC identifier
    /// (`MobileWorkspacePreview.rpcWorkspaceID.rawValue`).
    let workspaceChangeChipsByWorkspaceID: [String: MobileWorkspaceChangesChip]
    let openWorkspaceChanges: (@MainActor (MobileWorkspacePreview) -> Void)?

    let connectionRequiresReauth: Bool
    let connectionError: String?
    let host: String
    let isInitialConnectionLoading: Bool
    let initialConnectionTitle: String?
    let initialConnectionDescription: String?
    let enablesReorder: Bool
    let moveRows: ((IndexSet, Int) -> Void)?
    let canDropIntoGroup: ((MobileWorkspacePreview.ID, MobileWorkspaceGroupPreview.ID) -> Bool)?
    let dropIntoGroup: ((MobileWorkspacePreview.ID, MobileWorkspaceGroupPreview.ID) -> Void)?
    /// Builds the row's "Move to Group" picker on demand (context-menu open),
    /// so no per-row menu state is computed during list updates.
    var groupMoveMenu: ((MobileWorkspacePreview.ID) -> MobileWorkspaceGroupMoveMenu?)? = nil
    /// Moves the workspace to the end of a group, or out of its group when the
    /// target is `nil`. Same optimistic move path as drag-and-drop.
    var moveToGroup: ((MobileWorkspacePreview.ID, MobileWorkspaceGroupPreview.ID?) -> Void)? = nil

    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    /// What closing a workspace asks first; `nil` result closes at once.
    /// Defaults to the Mac question.
    var closeConfirmation: (MobileWorkspacePreview.ID) -> MobileWorkspaceCloseConfirmation? = { _ in .macWorkspace }
    let setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    let setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    let renameRequest: ((MobileWorkspacePreview.ID) -> Void)?
    var customizeRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil
    let createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let renameWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)?
    var renameWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    let setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    let ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    var ungroupWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    let deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    var deleteWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    let toggleGroupCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    let showAll: () -> Void
    let signOut: (() -> Void)?
    let retryInitialConnection: (() -> Void)?
    let showAddDevice: (() -> Void)?
    let reconnect: (() -> Void)?
    let refresh: (@Sendable () async -> Void)?
    var cancelRefresh: (() -> Void)? = nil
    var cancelRefreshOnDisappear: (() -> Void)? = nil
    var beginRefresh: (() -> UUID?)? = nil
    var cancelRefreshAttempt: ((UUID?) -> Void)? = nil
    var cancelRefreshAttemptOnDisappear: ((UUID?) -> Void)? = nil
    var emptyStateLayoutChanged: (() -> Void)? = nil
    var shouldCancelRefreshOnDisappear: (() -> Bool)? = nil
    var isRetryOwnerCurrentOnDisappear: (() -> Bool)? = nil

    func makeCoordinator() -> WorkspaceListTableCoordinator {
        let coordinator = WorkspaceListTableCoordinator(configuration: self)
        #if DEBUG
        coordinator.releaseGateUIProbe = releaseGateUIProbe
        coordinator.releaseGateSnapshotter = releaseGateSnapshotter
        #endif
        return coordinator
    }

    func makeUIViewController(context: Context) -> WorkspaceListTableViewController {
        let viewController = WorkspaceListTableViewController()
        let tableView = viewController.tableView
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.keyboardDismissMode = .interactive
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderHeight = 0
        tableView.sectionFooterHeight = 0
        tableView.rowHeight = UITableView.automaticDimension
        tableView.accessibilityIdentifier = "MobileWorkspaceList"
        context.coordinator.attach(
            to: tableView,
            viewController: viewController
        )
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: WorkspaceListTableViewController,
        context: Context
    ) {
        #if DEBUG
        context.coordinator.releaseGateUIProbe = releaseGateUIProbe
        context.coordinator.releaseGateSnapshotter = releaseGateSnapshotter
        #endif
        context.coordinator.update(
            configuration: self,
            in: uiViewController.tableView
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: WorkspaceListTableViewController,
        coordinator: WorkspaceListTableCoordinator
    ) {
        coordinator.detach()
        uiViewController.detach()
    }
}
#endif
