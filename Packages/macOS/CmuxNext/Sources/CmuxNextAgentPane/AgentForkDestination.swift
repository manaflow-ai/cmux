public import CmuxNextActions

/// Where a forked conversation opens: beside the chat in one of four directions, in a new
/// strip column on either side of the chat's column or a new row below it, in a new tab after
/// it, in a new workspace, or in a new window.
///
/// One value names the destination for every entry point that forks: the palette's Fork
/// Conversation step, the chat's right-click menu, the chat page's own Fork (`chat.openTab`'s
/// `placement`), and the CLI (`cmux agent fork-conversation-to-right`).
public enum AgentForkDestination: String, CaseIterable, Sendable {
    /// A new split right of the chat. The default destination (Fork Conversation's shortcut).
    case right
    /// A new split left of the chat.
    case left
    /// A new split above the chat.
    case up
    /// A new split below the chat.
    case down
    /// A new scrolling column right after the chat's column (New Column Right).
    case columnRight
    /// A new scrolling column right before the chat's column (New Column Left).
    case columnLeft
    /// A new row below the chat's row, in its column (New Row; needs rows and `rows-v1`).
    case row
    /// A new tab after the chat's, in its pane.
    case tab
    /// A new workspace, placed as Cmd-N places one.
    case workspace
    /// A new window showing a new workspace.
    case window

    /// The destination a fork takes when none is named.
    public static let `default`: AgentForkDestination = .right

    /// Every entry point uses the same default when the page names no destination.
    public init(placement: String?) {
        self = placement.flatMap(Self.init(rawValue:)) ?? .default
    }

    /// The catalog action that forks to this destination (`cmux agent fork-conversation-…`).
    public var actionID: ActionID {
        switch self {
        case .right: "palette.forkAgentConversationRight"
        case .left: "palette.forkAgentConversationLeft"
        case .up: "palette.forkAgentConversationTop"
        case .down: "palette.forkAgentConversationBottom"
        case .columnRight: "palette.forkAgentConversationNewColumnRight"
        case .columnLeft: "palette.forkAgentConversationNewColumnLeft"
        case .row: "palette.forkAgentConversationNewRow"
        case .tab: "palette.forkAgentConversationNewTab"
        case .workspace: "palette.forkAgentConversationNewWorkspace"
        case .window: "palette.forkAgentConversationNewWindow"
        }
    }

    /// How the fork's tab reaches this destination from the chat's pane.
    public enum Opening: Sendable, Equatable {
        /// Made in its new split in one daemon commit (`conversation-tab-split-v1`), shown in the
        /// gesture's turn (right, down).
        case split
        /// A tab in the chat's pane, shown there (New Tab).
        case tab
        /// Made unselected in the chat's pane and kept out of its strip, then moved where it goes; it
        /// takes the keyboard once it landed there, so the chat's pane never shows it on the way
        /// (left, up, a strip column or row, a workspace, a window).
        case moved
    }

    /// How the fork's tab reaches this destination (``Opening``).
    public var opening: Opening {
        switch self {
        case .right, .down: .split
        case .tab: .tab
        case .left, .up, .columnRight, .columnLeft, .row, .workspace, .window: .moved
        }
    }

    /// The Move Tab action that takes a fork made in the chat's pane to this destination: `tab.moveToNewSplit` for a
    /// split (left, up, or right and down on a daemon without `conversation-tab-split-v1`), Move Tab to New Workspace
    /// for a workspace or a window (which then shows it); nil for a strip column or row (`DaemonService.placeFork`) and a tab.
    public var moveAction: ActionID? {
        switch self {
        case .left, .up, .right, .down: "tab.moveToNewSplit"
        case .workspace: "palette.moveTabToNewWorkspace"
        case .window: "tab.moveToNewWindow"
        case .columnRight, .columnLeft, .row, .tab: nil
        }
    }

    /// The `direction` argument of `tab.moveToNewSplit` for a split destination, else nil.
    public var splitDirection: String? {
        switch self {
        case .right: "right"
        case .left: "left"
        case .up: "up"
        case .down: "down"
        case .columnRight, .columnLeft, .row, .tab, .workspace, .window: nil
        }
    }
}
