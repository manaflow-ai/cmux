import Foundation

/// Snapshot cache keys and the effective row color, split from
/// `SidebarWorkspaceSnapshotFactory.swift` to keep it within its file-length budget.
extension SidebarWorkspaceSnapshotFactory {
    /// The color a workspace row draws. A manual workspace color always wins, then
    /// the group's color, then the per-host origin color (nil when that flag is off).
    static func effectiveColorHex(
        workspaceColorHex: String?,
        groupColorHex: String?,
        originColorHex: String?
    ) -> String? {
        workspaceColorHex ?? groupColorHex ?? originColorHex
    }

    /// The cache key for `workspace`'s row. The snapshot and the sidebar's cache reconcile both
    /// build it here, so they can't disagree on the effective color.
    @MainActor
    static func presentationKey(
        workspace: Workspace,
        settings: SidebarTabItemSettingsSnapshot,
        showsAgentActivity: Bool,
        groupColorHex: String?,
        originColorHex: String?,
        hostTitleSuffix: String?
    ) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
        presentationKey(
            settings: settings,
            showsAgentActivity: showsAgentActivity,
            customColorHex: effectiveColorHex(
                workspaceColorHex: workspace.customColor,
                groupColorHex: groupColorHex,
                originColorHex: originColorHex
            ),
            hasManualCustomColor: workspace.customColor != nil,
            hostTitleSuffix: hostTitleSuffix
        )
    }

    static func presentationKey(
        settings: SidebarTabItemSettingsSnapshot,
        showsAgentActivity: Bool,
        customColorHex: String?,
        hasManualCustomColor: Bool = false,
        hostTitleSuffix: String? = nil
    ) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: settings.showsWorkspaceDescription,
            usesVerticalBranchLayout: settings.branchDirectory.branchLayout == .vertical,
            showsGitBranch: settings.showsGitBranch,
            usesViewportAwarePath: settings.usesLastSegmentPath,
            showsAgentActivity: showsAgentActivity,
            compactsAgentStatus: settings.compactsAgentStatus,
            compactStatusIcons: settings.compactStatusIcons,
            visibleAuxiliaryDetails: settings.visibleAuxiliaryDetails,
            customColorHex: customColorHex,
            hasManualCustomColor: hasManualCustomColor,
            hostTitleSuffix: hostTitleSuffix
        )
    }
}
