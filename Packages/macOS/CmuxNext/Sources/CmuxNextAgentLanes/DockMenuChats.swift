public import CmuxNextAgentActivity
public import Foundation

/// The chats the Dock icon's menu lists (Leo 2026-11-03, after Claude's and Codex's Dock menus):
/// Continue "<last chat>", then an Unread section and a Recent section of up to `shown` chats each,
/// with the rest of each under More. A pure value built from a copy of the lanes and the Priority
/// marks, when the menu opens (`make`, one pass that keeps only the newest chats).
public nonisolated struct DockMenuChats: Equatable, Sendable {
    /// One chat row: the session it opens and its title, already shortened for a menu.
    public struct Chat: Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// The chat Continue opens: the one that changed last.
    public var last: Chat?
    public var unread: [Chat] = []
    /// Unread chats past the first `shown`, newest first, at most `more`.
    public var unreadMore: [Chat] = []
    /// The newest chats after `last`, leaving out the unread ones the menu already shows.
    public var recent: [Chat] = []
    public var recentMore: [Chat] = []

    public init(last: Chat? = nil, unread: [Chat] = [], unreadMore: [Chat] = [], recent: [Chat] = [], recentMore: [Chat] = []) {
        self.last = last
        self.unread = unread
        self.unreadMore = unreadMore
        self.recent = recent
        self.recentMore = recentMore
    }

    public static let empty = DockMenuChats()

    /// The longest title a row shows, in characters; a longer one ends in an ellipsis.
    public static let titleLimit = 48

    /// The menu's chats from `lanes` (every session of this Mac's acpmux and the peers it
    /// mirrors). Left out: archived and snoozed chats (the Priority view's marks) and
    /// agent-started sessions acpmux keeps off the sidebar until a tab opens them. A chat the
    /// person marked read in its current state is not unread. Newest first by last change.
    ///
    /// One pass that keeps only the newest chats the rows can show (Continue, Recent and its More, and the unread
    /// ones Recent leaves out; Unread and its More), never a sort of every chat: the menu builds this when it opens.
    public static func make(lanes: some Collection<AgentActivityLane>, marks: AgentPriorityMarks.State, now: Date = Date(),
                            shown: Int = 3, more: Int = 10) -> DockMenuChats {
        var newest = Newest(limit: 1 + shown + more + shown)
        var newestUnread = Newest(limit: shown + more)
        for lane in lanes {
            guard !lane.sidebarRequiresOpen, !marks.archived.contains(lane.id) else { continue }
            // A stamp (a string) is made only for a chat that has a snooze or read mark.
            if marks.snoozed[lane.id] != nil, marks.isSnoozed(lane.id, stamp: AgentPriorityMarks.stamp(lane), now: now) { continue }
            newest.offer(lane)
            if lane.unread, marks.read[lane.id].map({ $0 != AgentPriorityMarks.stamp(lane) }) ?? true { newestUnread.offer(lane) }
        }
        guard let first = newest.lanes.first else { return .empty }
        let unreadLanes = newestUnread.lanes
        let unread = unreadLanes.prefix(shown).map(chat)
        let unreadMore = unreadLanes.dropFirst(shown).prefix(more).map(chat)
        let shownUnread = Set(unread.map(\.id))
        let recentLanes = newest.lanes.dropFirst().filter { !shownUnread.contains($0.id) }
        return DockMenuChats(last: chat(first), unread: Array(unread), unreadMore: Array(unreadMore),
                             recent: recentLanes.prefix(shown).map(chat), recentMore: recentLanes.dropFirst(shown).prefix(more).map(chat))
    }

    /// The `limit` newest lanes offered, newest first (``newerFirst``).
    private struct Newest {
        let limit: Int
        private(set) var lanes: [AgentActivityLane] = []

        init(limit: Int) {
            self.limit = limit
            lanes.reserveCapacity(limit + 1)
        }

        mutating func offer(_ lane: AgentActivityLane) {
            guard limit > 0 else { return }
            if lanes.count == limit, let last = lanes.last, !DockMenuChats.newerFirst(lane, last) { return }
            var low = 0
            var high = lanes.count
            while low < high {
                let middle = (low + high) / 2
                if DockMenuChats.newerFirst(lanes[middle], lane) { low = middle + 1 } else { high = middle }
            }
            lanes.insert(lane, at: low)
            if lanes.count > limit { lanes.removeLast() }
        }
    }

    /// When a lane last changed: its last output, else when it entered its state, else its start.
    static func changed(_ lane: AgentActivityLane) -> Date {
        lane.updatedAt ?? lane.since ?? lane.createdAt ?? .distantPast
    }

    private static func newerFirst(_ a: AgentActivityLane, _ b: AgentActivityLane) -> Bool {
        let (left, right) = (changed(a), changed(b))
        return left != right ? left > right : a.id < b.id
    }

    private static func chat(_ lane: AgentActivityLane) -> Chat {
        Chat(id: lane.id, title: title(lane.title.isEmpty ? lane.name : lane.title))
    }

    /// `raw` on one line (runs of whitespace and newlines become one space), at most `limit`
    /// characters with an ellipsis when cut.
    public static func title(_ raw: String, limit: Int = titleLimit) -> String {
        let line = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces) + "…"
    }
}
