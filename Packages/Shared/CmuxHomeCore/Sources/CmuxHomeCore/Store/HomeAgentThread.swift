public import Foundation

/// One subagent's chat with the Chief in one conversation, as the agent pane shows it (user 2026-11-03,
/// msg 19960): the task the Chief sent it, how long it worked, and every later message either way.
///
/// `HomeStore.agentThread(_:in:)` builds it from the Chief's run rows Home already reads (its `tell`
/// steps and the agents' reports), so a local and a Cloud Chief give the same thread.
public struct HomeAgentThread: Hashable, Sendable {
    /// One message after the task: one to the agent (`outgoing`, the Chief's or the person's) or the agent's
    /// report or status note.
    public struct Entry: Hashable, Sendable {
        /// The run step's id (stable across reads).
        public var id: String
        /// True for a message to the agent (the Chief's or the person's); false for the agent's.
        public var outgoing: Bool
        /// The message's words (a status note keeps its parentheses).
        public var text: String
        /// When the step was written.
        public var date: Date
        /// Who wrote it: the label over it in the pane.
        public var sender: HomeAgentSender

        /// - Parameters:
        ///   - id: The run step's id.
        ///   - outgoing: True for a message to the agent (the Chief's or the person's).
        ///   - text: The words.
        ///   - date: When the step was written.
        ///   - sender: Who wrote it; nil: the Chief for an outgoing message, else the agent.
        public init(id: String, outgoing: Bool, text: String, date: Date, sender: HomeAgentSender? = nil) {
            self.id = id
            self.outgoing = outgoing
            self.text = text
            self.date = date
            self.sender = sender ?? (outgoing ? .chief : .agent)
        }
    }

    /// The agent's id (`a12`).
    public var peer: String
    /// The task's title (``HomeAgentMessageRow/title(of:)``), else ``peer``.
    public var title: String
    /// Where it stands, from its newest message.
    public var state: HomeAgentMessageRow.PeerState
    /// The Chief's first message to it (the "Sent via Chief" bubble); nil when the Chief sent it nothing here.
    public var task: String?
    /// Every message after the task, oldest first.
    public var entries: [Entry]
    /// Its first message's time.
    public var startedAt: Date
    /// Its newest message's time once it reported or stopped; nil while it works.
    public var endedAt: Date?
    /// Its newest report's or status note's time; nil before it wrote back. The unread dot compares this.
    public var newestReportAt: Date?
    /// The Chief's link to the agent's session and workspace (`cmux://chief/<home>/session/<id>`, the
    /// link the Chief writes for each mention of the agent); nil when the Chief wrote none.
    public var workspaceLink: URL?

    /// - Parameters:
    ///   - peer: The agent's id.
    ///   - title: The task's title.
    ///   - state: Where it stands.
    ///   - task: The Chief's first message to it.
    ///   - entries: The later messages, oldest first.
    ///   - startedAt: Its first message's time.
    ///   - endedAt: Its newest message's time once done; nil while it works.
    ///   - newestReportAt: Its newest report's time.
    ///   - workspaceLink: The Chief's link to its session.
    public init(peer: String, title: String, state: HomeAgentMessageRow.PeerState, task: String?, entries: [Entry],
                startedAt: Date, endedAt: Date?, newestReportAt: Date?, workspaceLink: URL?) {
        self.peer = peer
        self.title = title
        self.state = state
        self.task = task
        self.entries = entries
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.newestReportAt = newestReportAt
        self.workspaceLink = workspaceLink
    }

    /// The agent's acpmux session id, from the Chief's link (``workspaceLink``); nil without a link.
    public var session: String? {
        guard let link = workspaceLink?.absoluteString, let slash = link.lastIndex(of: "/") else { return nil }
        let token = link[link.index(after: slash)...]
        return token.isEmpty ? nil : String(token)
    }

    /// How long it worked: from its first message to its end, or to `now` while it works.
    ///
    /// - Parameter now: The current time (injected so tests and redraws agree).
    /// - Returns: The duration in seconds, never negative.
    public func workedFor(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// The newest Chief link to `peer`'s session in `texts`: a Markdown link labelled with the id whose
    /// target is `cmux://chief/<8 hex>/session/<token>` (optchat-chief `workspaces::subagent_link`).
    ///
    /// - Parameters:
    ///   - peer: The agent's id.
    ///   - texts: The Chief's message texts, oldest first.
    /// - Returns: The link, or nil when no text names one.
    public static func workspaceLink(for peer: String, in texts: some Sequence<String>) -> URL? {
        let label = "[\(peer)](cmux://chief/"
        var found: URL?
        for text in texts {
            var rest = text[...]
            while let start = rest.range(of: label) {
                let target = rest[rest.index(start.lowerBound, offsetBy: peer.count + 3)...]
                guard let end = target.firstIndex(of: ")") else { break }
                let link = String(target[..<end])
                if isSubagentLink(link), let url = URL(string: link) { found = url }
                rest = target[end...]
            }
        }
        return found
    }

    /// `cmux://chief/<8 lowercase hex>/session/<token>`, the only form the Chief writes.
    private static func isSubagentLink(_ link: String) -> Bool {
        let parts = link.dropFirst("cmux://".count).split(separator: "/", omittingEmptySubsequences: false)
        guard link.hasPrefix("cmux://chief/"), parts.count == 4, parts[0] == "chief", parts[2] == "session" else { return false }
        let hex = parts[1].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        let token = parts[3].utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 }
        return parts[1].count == 8 && hex && !parts[3].isEmpty && parts[3].count <= 200 && token
    }
}
