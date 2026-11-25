/// Where a person's new tab goes when it is opened from an agent chat
/// (lawrence-call-1006 D, two columns like the Codex app). The rules that
/// pick one are Rust's (cmux-tui/crates/cmux-window-rules `chat`); the app
/// asks them through CmuxNextWindowRules. The chat dock is
/// the left dock column with the agent chat role: tools opened from it are
/// tabs in the scrolling strip. It shows its tab bar like every pane
/// (cx-v4dmy).
public nonisolated enum ChatColumnPlacement: Equatable, Sendable {
    /// What a pick on a New Tab page in the chat dock does when a scrolling pane is beside it.
    /// Kept in the layout domain so the app's composition root only applies the decision.
    public enum DockPick: Equatable, Sendable {
        /// The pick takes the usual route (nothing beside the dock).
        case usual
        /// The pick opens in the strip beside the dock.
        case beside(closesPage: Bool)

        public static func resolve(hasStrip: Bool, keep: Bool) -> Self {
            hasStrip ? .beside(closesPage: !keep) : .usual
        }
    }

    /// A tab in the pane it was opened from.
    case here
    /// A tab in this pane of the scrolling strip.
    case tab(in: PaneID)
    /// The chat is alone on its screen: it moves into a new left dock with
    /// the agent chat role, and the new tab stays in its pane.
    case dockChat
    /// The chat dock is a pinned column alone on its screen (Home with
    /// nothing beside it, `pinned-dock-alone-v1`): the new tab opens in a new
    /// column right of it, whether or not the dock takes dragged tabs.
    case besideDock

    /// `screen`'s columns in strip order. A screen stored as one split tree
    /// is one implicit column.
    public nonisolated static func columns(of screen: LayoutScreen, containing pane: PaneID) -> [LayoutColumn] {
        screen.layout.columns.isEmpty
            ? screen.column(containing: pane).map { [$0] } ?? [] : screen.layout.columns
    }
}

/// Where a new agent chat opens (lawrence-call-1006 D): the agent chat is a
/// docked column on the left (the dock column with the agent chat role),
/// never a tab in the strip.
public nonisolated enum NewChatPlacement: Equatable, Sendable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in the chat dock's pane (or, beside Home's pinned chat dock,
    /// in the first scrolling pane).
    case dock(PaneID)
    /// A new left chat dock, made from the chat once it exists.
    case newDock
    /// A new column right of the chat dock: Home's pinned dock alone on its screen
    /// (`pinned-dock-alone-v1`) takes no chat and has no scrolling pane beside it.
    case besideDock
}
