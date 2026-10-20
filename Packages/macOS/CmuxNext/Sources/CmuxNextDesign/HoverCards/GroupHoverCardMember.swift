public import Foundation

/// One member of a group as its card summarizes it: a sidebar group's workspace or a tab group's
/// tab. Each caller maps its own model into this value, so the summary is one pure function for
/// both kinds of group.
public nonisolated struct GroupHoverCardMember: Sendable, Hashable {
    /// What the member is doing, as the card counts it.
    public enum Activity: Sendable, Hashable {
        case idle
        /// An agent works or a command runs.
        case working
        /// Waiting for the person.
        case waiting
        /// Failed.
        case failed
    }

    public var title: String
    public var activity: Activity
    /// Unread items (a dot counts as one).
    public var unread: Int
    /// When the member last changed; nil when unknown.
    public var lastActivity: Date?
    public var branch: String?
    /// Listening ports as the member reports them (":3000, :5173").
    public var ports: String?

    public init(title: String, activity: Activity = .idle, unread: Int = 0, lastActivity: Date? = nil,
                branch: String? = nil, ports: String? = nil) {
        self.title = title
        self.activity = activity
        self.unread = unread
        self.lastActivity = lastActivity
        self.branch = branch
        self.ports = ports
    }
}

extension GroupHoverCardMember.Activity {
    /// The card's count for a status indicator state: busy, paused and working count as working.
    public init(_ state: StatusIndicatorState) {
        switch state {
        case .idle, .success: self = .idle
        case .busy, .paused, .working: self = .working
        case .waiting: self = .waiting
        case .error: self = .failed
        }
    }
}
