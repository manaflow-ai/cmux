import Foundation

/// A typed local op the user made that its owner (the daemon) has not
/// settled yet. The store shows it on top of the confirmed mirror
/// (plans/cmux-next/OWNERSHIP-PRINCIPLES.md, "Clients are projections").
/// Applying an intent must be idempotent and conservation-safe: it never
/// adds or removes a tab or a workspace, and it is a no-op when its tab,
/// workspace or group is not in the mirror.
public enum Intent: Sendable, Hashable {
    /// `move-tab`: `surface` into `pane` at final display `index`
    /// (`TabDragOutcome.strip`, a palette or keyboard move).
    case moveTab(surface: SurfaceID, toPane: PaneID, index: Int)
    /// `rename-tab`; nil or empty clears the custom name (shown as nil).
    case renameTab(surface: SurfaceID, name: String?)
    /// `set-tab-pinned`.
    case setTabPinned(surface: SurfaceID, pinned: Bool)
    /// `rename-workspace`.
    case renameWorkspace(key: WorkspaceKey, name: String)
    /// `move-workspace`: to final daemon-order `index` (clamped).
    case moveWorkspace(key: WorkspaceKey, index: Int)
    /// `move-workspace-to-group` without an index: into `group` (nil
    /// ungroups), keeping its place in the daemon order.
    case setWorkspaceGroup(key: WorkspaceKey, group: WorkspaceGroupID?)
    /// `move-workspace-to-group` with an index: into `group` (nil
    /// ungroups) at final `index` among that section's other members.
    case placeWorkspace(key: WorkspaceKey, group: WorkspaceGroupID?, index: Int)
    /// `update-workspace-group` with `collapsed`.
    case setWorkspaceGroupCollapsed(WorkspaceGroupID, collapsed: Bool)
    /// `update-tab-group` with `collapsed`.
    case setTabGroupCollapsed(TabGroupID, collapsed: Bool)
    /// `set-row-heights` (`rows-v1`): every row of `column`, in permille.
    /// A row divider release (plans/cmux-next/rows.md Z1).
    case setRowHeights(column: ColumnID, heights: [RowHeightValue])
}

/// One row's height in permille (`set-row-heights` `heights[]`).
public struct RowHeightValue: Sendable, Hashable, Codable {
    public var row: RowID
    public var height: Int

    public init(row: RowID, height: Int) {
        self.row = row
        self.height = height
    }
}

/// How an intent left the log. Each intent leaves exactly once.
public enum IntentSettlement: Sendable, Hashable {
    /// The daemon's echo of its transaction was applied.
    case echoed
    /// The store applied every event up to the intent's settle sequence
    /// (today the event sequence read after the command's reply; later the
    /// `request-settled` sequence of `mutation-echo-v1`).
    case applied
    /// The command failed.
    case rejected
}
