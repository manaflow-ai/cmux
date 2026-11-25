public import Foundation

/// An agent chat's task list across its turns, as acpmux keeps it (the summary's `taskList`,
/// `task_list.rs`): what is done and what is next. The harness's own plan keeps it (Claude Code's
/// TodoWrite, Codex's update_plan), else the chat's agent or its Chief (`_acpmux/task_list/set`).
/// A sidebar row reads its counts and lines; the Chief's Plans view (cmux.chief-views) draws the
/// steps of every chat at once.
public nonisolated struct AgentTaskList: Hashable, Sendable {
    /// Who keeps it.
    public enum Source: String, Hashable, Sendable {
        /// The harness's own plan events.
        case harness
        /// The chat's own agent.
        case agent
        /// The Chief or the app.
        case chief
    }

    /// One step as acpmux keeps it (`TaskItem`): its masked words and where it stands.
    public struct Step: Hashable, Sendable {
        public enum Status: String, Hashable, Sendable {
            case pending
            case inProgress = "in_progress"
            case completed
        }

        public let content: String
        public let status: Status

        public init(content: String, status: Status) {
            self.content = content
            self.status = status
        }
    }

    public let source: Source
    /// Steps completed.
    public let done: Int
    /// Every step; more than zero.
    public let total: Int
    /// The step in progress, masked by acpmux; nil when none is.
    public let current: String?
    /// The next step still pending; nil when none is left.
    public let next: String?
    /// When it last changed.
    public let updatedAt: Date?
    /// Every step in order (the summary's `items`); empty from a summary that predates them.
    public let steps: [Step]

    public init(source: Source, done: Int, total: Int, current: String? = nil, next: String? = nil, updatedAt: Date? = nil,
                steps: [Step] = []) {
        self.source = source
        self.done = min(max(done, 0), max(total, 0))
        self.total = max(total, 0)
        self.current = current
        self.next = next
        self.updatedAt = updatedAt
        self.steps = steps
    }

    /// Every step is done.
    public var isFinished: Bool { done >= total }

    /// The summary's `taskList`; nil when absent, null, empty or not one.
    public static func of(_ value: Any?) -> AgentTaskList? {
        guard let list = value as? [String: Any], let total = (list["total"] as? NSNumber)?.intValue, total > 0 else { return nil }
        let text = { (key: String) in (list[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let at = (list["updatedAt"] as? NSNumber).flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue / 1000) : nil }
        return AgentTaskList(source: text("source").flatMap(Source.init(rawValue:)) ?? .harness,
                             done: (list["done"] as? NSNumber)?.intValue ?? 0, total: total,
                             current: text("current"), next: text("next"), updatedAt: at, steps: steps(list["items"]))
    }

    /// The summary's `items`, leniently: a step with no words or an unknown status is left out.
    private static func steps(_ value: Any?) -> [Step] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let content = item["content"] as? String, !content.isEmpty,
                  let status = (item["status"] as? String).flatMap(Step.Status.init(rawValue:)) else { return nil }
            return Step(content: content, status: status)
        }
    }
}
