import CmuxNextBridge
import CmuxNextLayout

/// Where a new agent chat opens (lawrence-call-1006 D): the agent chat is a
/// docked column on the left, never a tab in the strip.
enum NewChatPlacement: Equatable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in the chat dock's pane.
    case dock(LayoutPaneID)
    /// A new left chat dock, made from the chat once it exists.
    case newDock

    static func resolve(from pane: LayoutPaneID, columns: [LayoutColumn], isLoneChat: Bool) -> NewChatPlacement {
        .here
    }
}
