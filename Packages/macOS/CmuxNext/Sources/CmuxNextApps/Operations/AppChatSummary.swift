public import Foundation

/// One agent chat as `chat.list` reports it to apps: every chat on every machine, already in the
/// Priority view's rank order (plans/cmux-next/extensibility-DESIGN.md section 10).
public nonisolated struct AppChatSummary: Sendable, Hashable {
    /// What the chat needs from the person, in tier order.
    public enum State: String, Sendable, Hashable {
        /// A permission prompt or a question waits for the person.
        case needsYou = "needs_you"
        /// The last turn answered and nobody has seen it yet.
        case done
        /// The last turn failed.
        case failed
        /// The agent process or its machine is gone.
        case lost
        /// A pull request of the chat's has failing checks.
        case ciFailing = "ci_failing"
        /// A turn runs.
        case working
        /// Nothing runs and nothing is unseen.
        case idle
    }

    /// The chat's session id.
    public var id: String
    public var title: String
    /// The project (the session folder's name), else nil.
    public var project: String?
    /// The machine it runs on, nil on this Mac.
    public var machine: String?
    public var state: State
    /// The person has not seen the chat's latest result.
    public var unread: Bool
    /// The person pinned the chat.
    public var pinned: Bool

    /// - Parameters:
    ///   - id: The session id.
    ///   - title: The chat's title.
    ///   - project: The project name, or nil.
    ///   - machine: The machine name, or nil on this Mac.
    ///   - state: What the chat needs.
    ///   - unread: Whether the latest result is unseen.
    ///   - pinned: Whether the chat is pinned.
    public init(id: String, title: String, project: String? = nil, machine: String? = nil,
                state: State, unread: Bool = false, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.project = project
        self.machine = machine
        self.state = state
        self.unread = unread
        self.pinned = pinned
    }
}
