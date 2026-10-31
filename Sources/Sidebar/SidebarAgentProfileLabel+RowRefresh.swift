import Foundation

extension SidebarAgentProfileLabel {
    /// Workspaces whose sidebar rows must rebuild after a
    /// `.sharedLiveAgentIndexDidChange` notification. The live index is not
    /// observable, and rows read it in two places: the compact status glyph's
    /// tooltip (agent profiles) and, in normal mode with metadata shown, the
    /// "Claude account" row. Empty when neither is on screen; otherwise the
    /// workspaces the notification names (see `changedWorkspaceIds`).
    static func workspaceIdsToRefresh(
        afterIndexChange userInfo: [AnyHashable: Any]?,
        allWorkspaceIds: [UUID],
        compactsAgentStatus: Bool,
        showsMetadata: Bool
    ) -> [UUID] {
        guard compactsAgentStatus || showsMetadata else { return [] }
        return changedWorkspaceIds(userInfo, allWorkspaceIds: allWorkspaceIds)
    }

    /// `workspaceIdsToRefresh` for the sidebar's current settings.
    static func workspaceIdsToRefresh(
        afterIndexChange userInfo: [AnyHashable: Any]?,
        allWorkspaceIds: [UUID],
        settings: SidebarTabItemSettingsSnapshot
    ) -> [UUID] {
        workspaceIdsToRefresh(
            afterIndexChange: userInfo,
            allWorkspaceIds: allWorkspaceIds,
            compactsAgentStatus: settings.compactsAgentStatus,
            showsMetadata: settings.visibleAuxiliaryDetails.showsMetadata
        )
    }
}
