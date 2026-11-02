import Foundation

extension SidebarAgentProfileLabel {
    /// Workspaces whose sidebar rows must rebuild after a
    /// `.sharedLiveAgentIndexDidChange` notification. The live index is not
    /// observable, and rows read it in two places: the compact status glyph's
    /// tooltip (agent profiles) and, in normal mode with metadata shown, the
    /// "Claude account" row. Empty when neither is on screen; otherwise the
    /// workspaces the notification names (see `changedWorkspaceIds`). A full
    /// reload names none: in normal mode, where only the account row reads the
    /// index, it rebuilds just the rows `accountRowIsStale` reports, instead of
    /// building every row to compare it.
    static func workspaceIdsToRefresh(
        afterIndexChange userInfo: [AnyHashable: Any]?,
        allWorkspaceIds: [UUID],
        compactsAgentStatus: Bool,
        showsMetadata: Bool,
        accountRowIsStale: (UUID) -> Bool = { _ in true }
    ) -> [UUID] {
        guard compactsAgentStatus || showsMetadata else { return [] }
        let changed = changedWorkspaceIds(userInfo, allWorkspaceIds: allWorkspaceIds)
        guard !compactsAgentStatus, !namesWorkspaces(userInfo) else { return changed }
        return changed.filter(accountRowIsStale)
    }

    /// `workspaceIdsToRefresh` for the sidebar's current settings.
    static func workspaceIdsToRefresh(
        afterIndexChange userInfo: [AnyHashable: Any]?,
        allWorkspaceIds: [UUID],
        settings: SidebarTabItemSettingsSnapshot,
        accountRowIsStale: (UUID) -> Bool = { _ in true }
    ) -> [UUID] {
        workspaceIdsToRefresh(
            afterIndexChange: userInfo,
            allWorkspaceIds: allWorkspaceIds,
            compactsAgentStatus: settings.compactsAgentStatus,
            showsMetadata: settings.visibleAuxiliaryDetails.showsMetadata,
            accountRowIsStale: accountRowIsStale
        )
    }

    /// `workspaceIdsToRefresh` for the workspace list as rendered: a full reload rebuilds the
    /// rows whose shown Claude account row (`shownSnapshots`) differs from what the workspace's
    /// panes give now.
    @MainActor
    static func workspaceIdsToRefresh(
        afterIndexChange userInfo: [AnyHashable: Any]?,
        renderContext: VerticalTabsSidebar.WorkspaceListRenderContext,
        shownSnapshots: SidebarRowSnapshotCache
    ) -> [UUID] {
        workspaceIdsToRefresh(
            afterIndexChange: userInfo,
            allWorkspaceIds: renderContext.workspaceIds,
            settings: renderContext.tabItemSettings
        ) { workspaceId in
            guard let workspace = renderContext.workspaceById[workspaceId] else { return false }
            return SidebarWorkspaceSnapshotFactory.claudeAccountRowIsStale(
                workspace: workspace,
                shownEntries: shownSnapshots.snapshotsById[workspaceId]?.metadataEntries
            )
        }
    }

    /// Whether the notification names the workspaces it changed; a full reload names none.
    private static func namesWorkspaces(_ userInfo: [AnyHashable: Any]?) -> Bool {
        userInfo?["panelIdsByWorkspaceId"] is [UUID: Set<UUID>] || userInfo?["workspaceId"] is UUID
    }
}
