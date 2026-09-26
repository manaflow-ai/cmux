import CmuxWorkspaces
import Foundation

/// Effective group presentation copied into built-in sidebar snapshots.
struct ExtensionSidebarGroupIdentity: Equatable {
    let iconSymbol: String
    let colorHex: String?

    /// Uses the default sidebar's membership and configuration precedence.
    /// Resolve configuration once per group, before crossing row-list boundaries.
    @MainActor
    static func byWorkspaceId(
        workspaces: [Workspace],
        groups: [WorkspaceGroup],
        resolveConfig: (String?) -> CmuxResolvedWorkspaceGroupConfig?
    ) -> [UUID: Self] {
        let workspacesById = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(
            tabs: workspaces,
            groupsById: groupsById
        )
        var identitiesByGroupId: [UUID: Self] = [:]
        for group in groups {
            let anchorCwd = group.liveAnchorWorkspaceId.flatMap { workspacesById[$0]?.currentDirectory }
            let config = resolveConfig(anchorCwd)
            let color = group.customColor ?? config?.color
            guard group.iconSymbol != nil || config?.iconSymbol != nil || color != nil else { continue }
            identitiesByGroupId[group.id] = Self(
                iconSymbol: RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
                    explicit: group.iconSymbol,
                    configured: config?.iconSymbol
                ),
                colorHex: color
            )
        }
        var result: [UUID: Self] = [:]
        for workspace in workspaces {
            guard let groupId = membership[workspace.id] ?? nil else { continue }
            result[workspace.id] = identitiesByGroupId[groupId]
        }
        return result
    }
}
