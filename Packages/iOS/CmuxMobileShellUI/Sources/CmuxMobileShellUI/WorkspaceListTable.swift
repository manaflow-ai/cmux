#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

/// Immutable UIKit workspace-table input.
@MainActor
struct WorkspaceListTable {
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
    let connectionStatus: MobileMacConnectionStatus
    let workspaceChangesCapable: Bool
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

    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    let setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    let setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    let renameRequest: ((MobileWorkspacePreview.ID) -> Void)?
    var customizeRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil
    let createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let renameWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)?
    let setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    let ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let toggleGroupCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    let showAll: () -> Void
    let signOut: (() -> Void)?
    let retryInitialConnection: (() -> Void)?
    let showAddDevice: (() -> Void)?
    let reconnect: (() -> Void)?
    let refresh: (@Sendable () async -> Void)?
}
#endif
