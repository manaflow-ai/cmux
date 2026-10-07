import CmuxNextBridge
import CmuxNextLayout

/// Where a person's new terminal goes when it is opened from an agent chat
/// (lawrence-call-1006 D, two columns like the Codex app).
enum ChatColumnPlacement: Equatable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in this pane, outside the chat's column.
    case tab(in: LayoutPaneID)
    /// The chat's column is the screen's only one: a new column right of
    /// it, then the chat's column docks on the left.
    case newColumnDockingChat(LayoutColumnID)

    /// `columns` are the screen's, in strip order; `isChatColumn` says
    /// whether a column holds only agent chats.
    static func resolve(from pane: LayoutPaneID, columns: [LayoutColumn],
                        isChatColumn: (LayoutColumn) -> Bool) -> ChatColumnPlacement {
        .here
    }
}
