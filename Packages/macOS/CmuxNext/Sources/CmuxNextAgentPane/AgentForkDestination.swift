/// Where a forked conversation opens: beside the chat in one of four directions, in a new
/// tab after it, in a new workspace, or in a new window.
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

    /// The `direction` argument of `tab.moveToNewSplit` for a split destination, else nil.
    public var splitDirection: String? {
        switch self {
        case .right: "right"
        case .left: "left"
        case .up: "up"
        case .down: "down"
        case .tab, .workspace, .window: nil
        }
    }
}
