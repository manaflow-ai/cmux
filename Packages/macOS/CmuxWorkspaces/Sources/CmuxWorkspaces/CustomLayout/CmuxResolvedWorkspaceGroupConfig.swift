public import CmuxSettings

/// Resolved snapshot of a per-cwd workspace group entry, with the JSON key
/// normalized for matching and any `contextMenu` actions resolved against the
/// loaded action/command tables.
///
/// This is the resolved counterpart to one ``CmuxConfigWorkspaceGroupEntry``
/// from the `cmux.json` `workspaceGroups` wire schema: the app-side resolver
/// normalizes the entry's key, expands any glob, folds in the group color and
/// icon, and resolves each `contextMenu` action into a runnable
/// ``CmuxResolvedConfigContextMenuItem``.
public struct CmuxResolvedWorkspaceGroupConfig: Sendable, Equatable {
    /// The group key exactly as written in `cmux.json`.
    public let originalKey: String
    /// The key normalized for cwd matching (case/trailing-slash folded).
    public let normalizedKey: String
    /// Whether ``normalizedKey`` should be matched as a glob pattern.
    public let isGlob: Bool
    /// The group's accent color, if the entry declared one.
    public let color: String?
    /// The group's SF Symbol name, if the entry declared one.
    public let iconSymbol: String?
    /// The fully-resolved rows of the group's right-click context menu.
    public let contextMenuItems: [CmuxResolvedConfigContextMenuItem]
    /// Parsed override for where the `+` button places its new workspace.
    /// nil means "fall through to the global default."
    public let newWorkspacePlacement: WorkspaceGroupNewPlacement?

    /// Creates a resolved workspace group config from already-resolved fields.
    public init(
        originalKey: String,
        normalizedKey: String,
        isGlob: Bool,
        color: String?,
        iconSymbol: String?,
        contextMenuItems: [CmuxResolvedConfigContextMenuItem],
        newWorkspacePlacement: WorkspaceGroupNewPlacement?
    ) {
        self.originalKey = originalKey
        self.normalizedKey = normalizedKey
        self.isGlob = isGlob
        self.color = color
        self.iconSymbol = iconSymbol
        self.contextMenuItems = contextMenuItems
        self.newWorkspacePlacement = newWorkspacePlacement
    }
}
