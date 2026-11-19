public import CmuxNextAgentActivity
import CmuxNextCompat
public import Foundation

/// The chats the Dock icon's menu lists (Leo 2026-11-03, after Claude's and Codex's Dock menus):
/// Continue "<last chat>", then an Unread section and a Recent section of up to `shown` chats each,
/// with the rest of each under More. A pure value built from a copy of the lanes and the Priority
/// marks, off the main thread (`make`), so `applicationDockMenu(_:)` only reads it.
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
    public static func make(lanes: some Collection<AgentActivityLane>, marks: AgentPriorityMarks.State, now: Date = Date(),
                            shown: Int = 3, more: Int = 10) -> DockMenuChats {
        ScaleWork.add(.rebuilds)
        ScaleWork.add(.lanesWalked, lanes.count)
        let listed = lanes.filter { lane in
            guard !lane.sidebarRequiresOpen, !marks.archived.contains(lane.id) else { return false }
            return !marks.isSnoozed(lane.id, stamp: AgentPriorityMarks.stamp(lane), now: now)
        }.sorted(by: newerFirst)
        guard let first = listed.first else { return .empty }
        let unreadLanes = listed.filter { $0.unread && marks.read[$0.id] != AgentPriorityMarks.stamp($0) }
        let unread = unreadLanes.prefix(shown).map(chat)
        let unreadMore = unreadLanes.dropFirst(shown).prefix(more).map(chat)
        let shownUnread = Set(unread.map(\.id))
        let recentLanes = listed.dropFirst().filter { !shownUnread.contains($0.id) }
        return DockMenuChats(last: chat(first), unread: Array(unread), unreadMore: Array(unreadMore),
                             recent: recentLanes.prefix(shown).map(chat), recentMore: recentLanes.dropFirst(shown).prefix(more).map(chat))
    }

    /// ``make(lanes:marks:now:shown:more:)`` from lanes already in its order: `ordered` is every session newest
    /// first (``Order``), `unread` the sessions whose lane is unread (`AgentLaneStore.unread`). It walks `ordered`
    /// only until the Recent rows are full, and sorts only the unread lanes, so one session's change costs the
    /// menu the rows it shows, not every session. The same rows as `make(lanes:)` of the same lanes.
    public static func make(ordered: Order, lanes: [String: AgentActivityLane], unread: Set<String>, marks: AgentPriorityMarks.State,
                            now: Date = Date(), shown: Int = 3, more: Int = 10) -> DockMenuChats {
        func listed(_ lane: AgentActivityLane) -> Bool {
            guard !lane.sidebarRequiresOpen, !marks.archived.contains(lane.id) else { return false }
            return !marks.isSnoozed(lane.id, stamp: AgentPriorityMarks.stamp(lane), now: now)
        }
        ScaleWork.add(.lanesWalked, unread.count)
        let unreadLanes = unread.compactMap { lanes[$0] }
            .filter { $0.unread && listed($0) && marks.read[$0.id] != AgentPriorityMarks.stamp($0) }
            .sorted(by: newerFirst)
        let unreadShown = unreadLanes.prefix(shown).map(chat)
        let unreadMore = unreadLanes.dropFirst(shown).prefix(more).map(chat)
        let shownUnread = Set(unreadShown.map(\.id))
        var first: AgentActivityLane?
        var recentLanes: [AgentActivityLane] = []
        var walked = 0
        defer { ScaleWork.add(.lanesWalked, walked) }
        for key in ordered.keys {
            walked += 1
            guard let lane = lanes[key.id], listed(lane) else { continue }
            if first == nil {
                first = lane
            } else if !shownUnread.contains(lane.id) {
                recentLanes.append(lane)
                if recentLanes.count >= shown + more { break }
            }
        }
        guard let first else { return .empty }
        return DockMenuChats(last: chat(first), unread: Array(unreadShown), unreadMore: Array(unreadMore),
                             recent: recentLanes.prefix(shown).map(chat), recentMore: recentLanes.dropFirst(shown).prefix(more).map(chat))
    }

    /// Every session newest first by last change (``changed(_:)``, then id), kept by one session at a time
    /// (`DockMenuController`): a binary search finds where a changed session leaves and where it goes.
    public struct Order: Sendable {
        public struct Key: Hashable, Sendable {
            var changed: Date
            var id: String
        }

        public private(set) var keys: [Key] = []
        private var byID: [String: Date] = [:]

        public init() {}

        /// Every lane of `lanes`, sorted.
        public init(_ lanes: some Collection<AgentActivityLane>) {
            ScaleWork.add(.rebuilds)
            ScaleWork.add(.lanesWalked, lanes.count)
            keys = lanes.map { Key(changed: DockMenuChats.changed($0), id: $0.id) }.sorted(by: Self.before)
            byID = Dictionary(keys.map { ($0.id, $0.changed) }, uniquingKeysWith: { first, _ in first })
        }

        /// Session `id` is now `lane` (nil: it ended).
        public mutating func update(_ id: String, _ lane: AgentActivityLane?) {
            let next = lane.map { Key(changed: DockMenuChats.changed($0), id: id) }
            if let was = byID[id].map({ Key(changed: $0, id: id) }) {
                if was == next { return }
                let at = index(of: was)
                if at < keys.count, keys[at] == was { keys.remove(at: at) }
                byID[id] = nil
            }
            guard let next else { return }
            keys.insert(next, at: index(of: next))
            byID[id] = next.changed
        }

        private func index(of key: Key) -> Int {
            var (low, high) = (0, keys.count)
            var probes = 0
            defer { ScaleWork.add(.probes, probes) }
            while low < high {
                probes += 1
                let mid = (low + high) / 2
                if Self.before(keys[mid], key) { low = mid + 1 } else { high = mid }
            }
            return low
        }

        private static func before(_ a: Key, _ b: Key) -> Bool {
            a.changed != b.changed ? a.changed > b.changed : a.id < b.id
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
