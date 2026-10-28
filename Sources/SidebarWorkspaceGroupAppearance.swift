import CmuxWorkspaces
import Foundation

/// A workspace group's resolved sidebar appearance: the group's own color and
/// icon, else the `workspaceGroups.byCwd` entry for its live anchor's directory.
///
/// The group header and its member rows both read the color from here, so a
/// header and the workspaces under it never disagree.
@MainActor
struct SidebarWorkspaceGroupAppearance {
    /// The `workspaceGroups.byCwd` entry that matches the anchor's directory.
    let config: CmuxResolvedWorkspaceGroupConfig?
    /// Header tint, and the color member workspaces inherit.
    let colorHex: String?
    /// Whether the group has its own color, so Clear Color applies. False when
    /// `colorHex` comes only from a config entry.
    let hasCustomColor: Bool
    let iconSymbol: String

    init(group: WorkspaceGroup, workspaceById: [UUID: Workspace], configStore: CmuxConfigStore) {
        let anchorDirectory = group.liveAnchorWorkspaceId.flatMap { workspaceById[$0]?.currentDirectory }
        config = configStore.resolveWorkspaceGroupConfig(forCwd: anchorDirectory)
        colorHex = group.customColor ?? config?.color
        hasCustomColor = group.customColor != nil
        iconSymbol = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
            explicit: group.iconSymbol,
            configured: config?.iconSymbol
        )
    }

    /// The group color each grouped workspace inherits, keyed by workspace id.
    /// Ungrouped workspaces and groups without a color have no entry.
    static func inheritedColorHexes(
        workspaces: [Workspace],
        groups: [WorkspaceGroup],
        configStore: CmuxConfigStore
    ) -> [UUID: String] {
        guard !groups.isEmpty else { return [:] }
        let workspaceById = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        var colorHexByGroupId: [UUID: String] = [:]
        for group in groups {
            let appearance = Self(group: group, workspaceById: workspaceById, configStore: configStore)
            colorHexByGroupId[group.id] = appearance.colorHex
        }
        guard !colorHexByGroupId.isEmpty else { return [:] }
        var colorHexByWorkspaceId: [UUID: String] = [:]
        for workspace in workspaces {
            guard let groupId = workspace.groupId else { continue }
            colorHexByWorkspaceId[workspace.id] = colorHexByGroupId[groupId]
        }
        return colorHexByWorkspaceId
    }
}
