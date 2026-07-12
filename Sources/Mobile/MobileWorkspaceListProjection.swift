import CmuxWorkspaces
import Foundation

struct MobileWorkspaceListProjection: Hashable {
    let schemaVersion: Int
    let selectedTabID: UUID?
    let groups: [GroupValue]
    let workspaces: [MobileWorkspaceHierarchyProjection.ListValue]

    @MainActor
    init(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int]
    ) {
        schemaVersion = MobileWorkspaceHierarchyProjection.schemaVersion
        self.selectedTabID = selectedTabID
        self.groups = groups.map {
            .init(
                id: $0.id,
                name: $0.name,
                isCollapsed: $0.isCollapsed,
                isPinned: $0.isPinned,
                anchorWorkspaceID: $0.anchorWorkspaceId
            )
        }
        workspaces = tabs.map {
            MobileWorkspaceHierarchyProjection(
                workspace: $0,
                previewSignature: previewSignatures[$0.id]
            ).list
        }
    }

    /// Computes the list identity without retaining arrays for the previous
    /// snapshot. Each workspace value is hashed and released before sampling the
    /// next workspace.
    @MainActor
    static func digest(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int],
        fallbackNeedsConfirmClose: ((Workspace, UUID) -> Bool)? = nil
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(MobileWorkspaceHierarchyProjection.schemaVersion)
        hasher.combine(selectedTabID)
        hasher.combine(groups.count)
        for group in groups {
            hasher.combine(GroupValue(
                id: group.id,
                name: group.name,
                isCollapsed: group.isCollapsed,
                isPinned: group.isPinned,
                anchorWorkspaceID: group.anchorWorkspaceId
            ))
        }
        hasher.combine(tabs.count)
        for workspace in tabs {
            let list = MobileWorkspaceHierarchyProjection.observerListValue(
                workspace: workspace,
                previewSignature: previewSignatures[workspace.id],
                fallbackNeedsConfirmClose: { panelID in
                    if let fallbackNeedsConfirmClose {
                        return fallbackNeedsConfirmClose(workspace, panelID)
                    }
                    return workspace.terminalPanel(for: panelID)?.needsConfirmClose() ?? false
                }
            )
            list.hashObserverIdentity(into: &hasher)
        }
        return hasher.finalize()
    }
}
