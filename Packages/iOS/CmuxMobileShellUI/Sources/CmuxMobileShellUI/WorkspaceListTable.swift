#if os(iOS)
import CmuxMobileShellModel
import SwiftUI
import UIKit

/// UIKit-owned workspace list with exact, non-estimated row heights.
@MainActor
struct WorkspaceListTable: UIViewRepresentable {
    let items: [WorkspaceListTableItem]
    let workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    let groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    let groupHasUnreadByID: [MobileWorkspaceGroupPreview.ID: Bool]
    let filter: MobileWorkspaceListFilter
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let navigationStyle: WorkspaceNavigationStyle
    let wrapWorkspaceTitles: Bool
    let previewLineLimit: Int
    let unreadIndicatorLeftShift: Double
    let profilePictureLeftShift: Double
    let profilePictureSize: Double
    let connectionStatus: MobileMacConnectionStatus

    let connectionRequiresReauth: Bool
    let connectionRecoveryFailed: Bool
    let isRecoveringConnection: Bool
    let connectionError: String?
    let host: String
    let isInitialConnectionLoading: Bool
    let initialConnectionTitle: String?
    let initialConnectionDescription: String?
    let enablesReorder: Bool
    let moveRows: ((IndexSet, Int) -> Void)?

    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let requestWorkspaceClose: ((MobileWorkspacePreview.ID) -> Void)?
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    let setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    let setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    let renameRequest: ((MobileWorkspacePreview.ID) -> Void)?
    let createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let renameWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)?
    let setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    let ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let toggleGroupCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    let showAll: () -> Void
    let retryConnectionRecovery: (() -> Void)?
    let signOut: (() -> Void)?
    let retryInitialConnection: (() -> Void)?
    let showAddDevice: (() -> Void)?
    let reconnect: (() -> Void)?
    let refresh: (@Sendable () async -> Void)?
    let refreshCompletionGeneration: UInt64
    let refreshDidComplete: @MainActor () -> Void

    func makeCoordinator() -> WorkspaceListTableCoordinator {
        WorkspaceListTableCoordinator(configuration: self)
    }

    func makeUIView(context: Context) -> WorkspaceListTableContainerView {
        let containerView = WorkspaceListTableContainerView()
        let tableView = containerView.tableView
        context.coordinator.attach(to: containerView)
        context.coordinator.update(configuration: self, in: tableView)
        return containerView
    }

    func updateUIView(_ uiView: WorkspaceListTableContainerView, context: Context) {
        context.coordinator.update(
            configuration: self,
            in: uiView.tableView
        )
    }

    static func dismantleUIView(
        _ uiView: WorkspaceListTableContainerView,
        coordinator: WorkspaceListTableCoordinator
    ) {
        coordinator.detach(from: uiView)
    }
}

/// Neutral SwiftUI boundary around the UIKit-owned scrolling hierarchy.
///
/// SwiftUI sizes this view while the child table owns its refresh inset and
/// content offset. Keeping the scroll view off the representable boundary
/// prevents refresh geometry from resizing the SwiftUI host mid-gesture.
@MainActor
final class WorkspaceListTableContainerView: UIView {
    let tableView: WorkspaceListUITableView

    override init(frame: CGRect) {
        let tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
        self.tableView = tableView
        super.init(frame: frame)

        backgroundColor = .clear
        clipsToBounds = true
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
        addSubview(tableView)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceListTableContainerView does not support storyboards")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds
    }
}
#endif
