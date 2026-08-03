import CmuxCore
import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Immutable inputs used to assemble one workspace row when a lazy stack realizes it.
///
/// The sidebar owner resolves every live model read into this value before the
/// `LazyVStack`. Context-menu notifications and row-specific action closures
/// are intentionally assembled later so parent invalidations stay O(values),
/// not O(full row subtrees).
struct SidebarWorkspaceRowInput {
    let workspaceId: UUID
    let groupId: UUID?
    let index: Int
    let workspaceCount: Int
    let workspace: SidebarWorkspaceSnapshotBuilder.Snapshot
    let isActive: Bool
    let isMultiSelected: Bool
    let hasUserCustomTitle: Bool
    let hasCustomTitle: Bool
    let hasCustomDescription: Bool
    let customTitle: String?
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let unreadCount: Int
    let latestNotificationText: String?
    let showsAgentActivity: Bool
    let rowSpacing: CGFloat
    let showsModifierShortcutHints: Bool
    let isPointerHovering: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    let isBonsplitWorkspaceDropActive: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let isChecklistExpanded: Bool
    let checklistAddFieldActivationToken: Int
    let isChecklistPopoverPresented: Bool
    let isRemoteContextMenuEligible: Bool
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let inferredTaskStatus: WorkspaceTaskStatus
    let activeTodoOverride: WorkspaceTaskStatus?
    let isTodoStatusHidden: Bool

}
