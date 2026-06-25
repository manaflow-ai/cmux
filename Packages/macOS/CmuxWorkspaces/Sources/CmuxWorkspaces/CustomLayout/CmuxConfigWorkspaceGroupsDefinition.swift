public import Foundation

/// The `cmux.json` `workspaceGroups` block: per-cwd customization for sidebar
/// workspace groups, keyed by the anchor workspace's cwd.
///
/// Keys containing `*` or `?` are matched as fnmatch globs; otherwise they are
/// path prefixes. Longest match wins. `~` is expanded. This is the `Codable`,
/// `Sendable` wire image of the block; changing any token here is a wire-format
/// change to every user's `cmux.json`. The resolved snapshot
/// (``CmuxResolvedWorkspaceGroupConfig``) is computed app-side against the
/// loaded action/command tables.
public struct CmuxConfigWorkspaceGroupsDefinition: Codable, Sendable, Equatable {
    /// The per-cwd group entries, keyed by anchor-workspace cwd.
    public var byCwd: [String: CmuxConfigWorkspaceGroupEntry]?

    private enum CodingKeys: String, CodingKey {
        case byCwd
    }

    /// Creates a workspace-groups definition from an optional per-cwd map.
    public init(byCwd: [String: CmuxConfigWorkspaceGroupEntry]? = nil) {
        self.byCwd = byCwd
    }
}

/// One per-cwd entry in the `cmux.json` `workspaceGroups.byCwd` map: the visual
/// and behavioral overrides applied to a sidebar workspace group whose anchor
/// cwd matches the key.
///
/// `Codable`, `Sendable` wire image; its only non-primitive field is
/// ``contextMenu``, an array of ``CmuxConfigContextMenuItem``.
public struct CmuxConfigWorkspaceGroupEntry: Codable, Sendable, Equatable {
    /// The group's accent color override (a `cmux.json` color string), or `nil`.
    public var color: String?
    /// The group's icon override (an SF Symbol name), or `nil`.
    public var icon: String?
    /// The group header's context-menu rows, or `nil` to use the default menu.
    public var contextMenu: [CmuxConfigContextMenuItem]?
    /// Where a newly-created workspace lands inside the group when the user
    /// clicks the header's `+` button or invokes Cmd-N from a group member.
    /// Valid values: `"afterCurrent"` (after the current in-group workspace,
    /// falling back to top), `"top"` (immediately after the anchor), or
    /// `"end"` (after the last member). When omitted,
    /// falls back to the global default
    /// (the stored `workspaceGroups.newWorkspacePlacement` setting).
    public var newWorkspacePlacement: String?

    /// Creates a workspace-group entry with optional presentation and placement
    /// overrides.
    public init(
        color: String? = nil,
        icon: String? = nil,
        contextMenu: [CmuxConfigContextMenuItem]? = nil,
        newWorkspacePlacement: String? = nil
    ) {
        self.color = color
        self.icon = icon
        self.contextMenu = contextMenu
        self.newWorkspacePlacement = newWorkspacePlacement
    }
}
