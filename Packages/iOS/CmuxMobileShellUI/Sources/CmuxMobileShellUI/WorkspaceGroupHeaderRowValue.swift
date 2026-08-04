import CmuxMobileShellModel

struct WorkspaceGroupHeaderRowValue: Equatable {
    let group: MobileWorkspaceGroupPreview
    let hasUnread: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let isAnchorSelected: Bool
    let canCreateWorkspaceInGroup: Bool
    let canRenameGroup: Bool
    let canSetGroupPinned: Bool
    let canUngroupWorkspaceGroup: Bool
    let canDeleteWorkspaceGroup: Bool
    let canToggleCollapsed: Bool
    let unreadIndicatorLeftShift: Double
}
