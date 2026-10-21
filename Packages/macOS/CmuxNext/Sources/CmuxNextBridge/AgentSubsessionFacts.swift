import Foundation

/// What acpmux says about a sub-session (`hub/subsessions.rs`): a session an agent started with
/// its `start_session` tool. Read from the session summary of `_acpmux/watch` and its
/// `_acpmux/session_changed` pushes; nil for a session a person or a client started.
public nonisolated struct AgentSubsessionFacts: Hashable, Sendable {
    /// The session whose agent started this one (`startedBy`), at any depth: a client draws the
    /// tree from these links.
    public var startedBy: String
    /// Its name among its parent's sub-sessions (`shortName`).
    public var shortName: String?
    /// 1 under a root session, 2 under one of its sub-sessions, and so on (`depth`).
    public var depth: Int
    /// Prompts waiting behind the running turn (`queued`).
    public var queued: Int
    /// A finished turn no client has shown yet (`unread`).
    public var unread: Bool
    /// The session was closed (`status` `closed`): the sidebar no longer lists it.
    public var closed: Bool
    /// When acpmux made it (`createdAt`, Unix ms): siblings list in start order.
    public var createdAtMs: UInt64

    public init(startedBy: String, shortName: String? = nil, depth: Int = 1, queued: Int = 0, unread: Bool = false,
                closed: Bool = false, createdAtMs: UInt64 = 0) {
        self.startedBy = startedBy
        self.shortName = shortName
        self.depth = depth
        self.queued = queued
        self.unread = unread
        self.closed = closed
        self.createdAtMs = createdAtMs
    }

    /// The facts of one session summary; nil when no agent started it (no `startedBy`).
    public static func of(summary: [String: Any]) -> AgentSubsessionFacts? {
        guard let parent = (summary["startedBy"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parent.isEmpty, parent != summary["sessionId"] as? String else { return nil }
        let short = (summary["shortName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentSubsessionFacts(startedBy: parent, shortName: short?.isEmpty == false ? short : nil,
                                    depth: max(1, (summary["depth"] as? NSNumber)?.intValue ?? 1),
                                    queued: max(0, (summary["queued"] as? NSNumber)?.intValue ?? 0),
                                    unread: summary["unread"] as? Bool == true,
                                    closed: summary["status"] as? String == "closed",
                                    createdAtMs: (summary["createdAt"] as? NSNumber)?.uint64Value ?? 0)
    }

    /// The facts of every sub-session of a watch result.
    public static func all(_ result: [String: Any]) -> [String: AgentSubsessionFacts] {
        var facts: [String: AgentSubsessionFacts] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let link = of(summary: summary) { facts[id] = link }
        }
        return facts
    }
}

/// One sub-session under a chat, as ``AgentTurnStateStore/subsessions(of:)`` lists it: depth
/// first, siblings in start order.
public nonisolated struct AgentSubsessionEntry: Hashable, Sendable {
    /// The sub-session's acpmux session id.
    public var session: String
    /// 1 for a child of the chat, 2 for a grandchild, and so on.
    public var depth: Int
    public var facts: AgentSubsessionFacts
    /// Its turn state (`indicator`), nil when acpmux shows no dot.
    public var state: AgentTurnState?
    /// Its chat title (``AgentTurnStates/title(_:includingPrompt:)``), nil before it has one.
    public var title: String?

    public init(session: String, depth: Int, facts: AgentSubsessionFacts, state: AgentTurnState?, title: String?) {
        self.session = session
        self.depth = depth
        self.facts = facts
        self.state = state
        self.title = title
    }
}
