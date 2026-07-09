/// A validated `workspace.action` request, ready for the app to apply against
/// the live `TabManager`.
///
/// ``ControlWorkspaceActionResolution`` produces one of these once the action
/// key and its inputs (title, description, color) have passed validation. The
/// associated values carry only the already-validated inputs — the trimmed
/// title, the raw description (stored untrimmed, matching the legacy body), and
/// the resolved hex color — so the app-side `v2WorkspaceAction` mutation switch
/// performs the side effect without re-validating. Index/close-count/null
/// payload values are read from live state app-side after the mutation.
public enum ControlWorkspaceActionPlan: Sendable, Equatable {
    /// Pin the workspace (legacy `pin`).
    case pin
    /// Unpin the workspace (legacy `unpin`).
    case unpin
    /// Set the workspace's custom title to the trimmed value (legacy `rename`).
    case rename(title: String)
    /// Clear the workspace's custom title (legacy `clear_name`).
    case clearName
    /// Set the workspace's custom description to the raw, untrimmed value
    /// (legacy `set_description`).
    case setDescription(description: String)
    /// Clear the workspace's custom description (legacy `clear_description`).
    case clearDescription
    /// Move the workspace up one slot (legacy `move_up`).
    case moveUp
    /// Move the workspace down one slot (legacy `move_down`).
    case moveDown
    /// Move the workspace to the top (legacy `move_top`).
    case moveTop
    /// Close every other unpinned workspace (legacy `close_others`).
    case closeOthers
    /// Close unpinned workspaces above this one (legacy `close_above`).
    case closeAbove
    /// Close unpinned workspaces below this one (legacy `close_below`).
    case closeBelow
    /// Mark the workspace read (legacy `mark_read`).
    case markRead
    /// Mark the workspace unread (legacy `mark_unread`).
    case markUnread
    /// Set the workspace's tab color to the resolved hex (legacy `set_color`).
    case setColor(hex: String)
    /// Clear the workspace's tab color (legacy `clear_color`).
    case clearColor
}
