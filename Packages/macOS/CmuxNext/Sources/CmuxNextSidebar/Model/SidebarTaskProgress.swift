import Foundation

/// How far the workspace's agent chat is through its task list (acpmux's `taskList`, kept across
/// the chat's turns: its harness's plan, else what its agent or Chief keeps): the row's quiet
/// "3/7" and the hover card's done, now and next lines. Set only while steps are left
/// (`SidebarLaneStatus`); a finished list draws nothing, as the row's unread dot already says the
/// chat finished.
public nonisolated struct SidebarTaskProgress: Hashable, Sendable {
    /// Steps completed, at most `total`.
    public var done: Int
    /// Every step; more than zero.
    public var total: Int
    /// The step in progress; nil when none is.
    public var current: String?
    /// The next step still pending; nil when none is left.
    public var next: String?

    public init(done: Int, total: Int, current: String? = nil, next: String? = nil) {
        self.total = max(total, 1)
        self.done = min(max(done, 0), self.total)
        self.current = current
        self.next = next
    }

    /// The row's count, in figures only ("3/7"): it reads the same in every language.
    public var countText: String { "\(done)/\(total)" }
}
