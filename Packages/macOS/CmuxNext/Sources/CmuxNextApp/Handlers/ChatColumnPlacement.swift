import CmuxNextLayout

/// Where a person's new tab goes when it is opened from an agent chat
/// (lawrence-call-1006 D, two columns like the Codex app).
enum ChatColumnPlacement: Equatable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in this pane of the scrolling strip.
    case tab(in: LayoutPaneID)
    /// The docked chat has no scrolling column: a new one beside it.
    case newColumn
    /// The chat is alone on its screen: it moves into a new left dock with
    /// the agent chat role, and the new tab stays in its pane.
    case dockChat

    static func resolve(from pane: LayoutPaneID, columns: [LayoutColumn], recent: [LayoutPaneID] = [],
                        isLoneChat: (LayoutColumn) -> Bool) -> ChatColumnPlacement {
        .here
    }
}
