public import CmuxNextAgentActivity
public import CmuxNextSidebar
public import Foundation
public import Observation

/// The person's marks on the Priority view's chats, kept on this Mac: pinned, read, snoozed,
/// archived and dragged to a place, and whether the view is folded. A read or snooze mark holds
/// for the lane state it was made on (its `stamp`): when the chat moves on (a new question, a new
/// result) it shows again.
@Observable @MainActor
public final class AgentPriorityMarks {
    public static let shared = AgentPriorityMarks(defaults: .standard)

    public nonisolated struct State: Codable, Hashable, Sendable {
        public var pinned: Set<String> = []
        /// Session id to the stamp of the state the person marked read.
        public var read: [String: String] = [:]
        /// Session id to the stamp it was snoozed on and until when.
        public var snoozed: [String: Snooze] = [:]
        /// Archived from the view; acpmux hides it from its lists too.
        public var archived: Set<String> = []
        public var collapsed = false
        /// The Archived fold is open (folded by default).
        public var archivedOpen = false
        /// Session id to the place (0 is the top) the person dragged it to: it shows there until
        /// they drag it again, whatever its state (Leo 2026-10-21).
        public var placed: [String: Int] = [:]
        /// The filter chip picked while `sidebar.priorityView.filters` is on.
        public var filter: SidebarPriorityFilter = .all

        public nonisolated struct Snooze: Codable, Hashable, Sendable {
            public var stamp: String
            public var until: Date
        }

        public init() {}

        enum CodingKeys: String, CodingKey { case pinned, read, snoozed, archived, collapsed, placed, archivedOpen, filter }

        /// Each mark may be missing: marks saved by an older build still load.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pinned = try c.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
            read = try c.decodeIfPresent([String: String].self, forKey: .read) ?? [:]
            snoozed = try c.decodeIfPresent([String: Snooze].self, forKey: .snoozed) ?? [:]
            archived = try c.decodeIfPresent(Set<String>.self, forKey: .archived) ?? []
            collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
            archivedOpen = try c.decodeIfPresent(Bool.self, forKey: .archivedOpen) ?? false
            placed = try c.decodeIfPresent([String: Int].self, forKey: .placed) ?? [:]
            // A filter a later build added reads as All here.
            filter = (try? c.decodeIfPresent(SidebarPriorityFilter.self, forKey: .filter)) ?? .all
        }

        public func isSnoozed(_ id: String, stamp: String, now: Date) -> Bool {
            guard let snooze = snoozed[id] else { return false }
            return snooze.stamp == stamp && now < snooze.until
        }
    }

    public private(set) var state: State {
        didSet { if state != oldValue { save() } }
    }

    @ObservationIgnored private let defaults: UserDefaults?
    private static let key = "cmux.next.sidebar.priorityMarks"

    /// `defaults` nil keeps the marks in memory only (tests).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        state = saved ?? State()
    }

    /// What a mark on `lane` holds for: its state and since when, or the notice it shows when the
    /// lane names one (`markKey`: another machine's chat, whose notice may have no time).
    public nonisolated static func stamp(_ lane: AgentActivityLane) -> String {
        "\(lane.state.rawValue)@\(lane.markKey ?? String(lane.since.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0))"
    }

    public func markRead(_ lane: AgentActivityLane) { state.read[lane.id] = Self.stamp(lane) }

    public func togglePin(_ id: String) {
        if state.pinned.remove(id) == nil { state.pinned.insert(id) }
    }

    public func snooze(_ lane: AgentActivityLane, for duration: TimeInterval = 60 * 60, now: Date = Date()) {
        state.snoozed[lane.id] = State.Snooze(stamp: Self.stamp(lane), until: now.addingTimeInterval(duration))
    }

    /// Hides the chat; its pin stays until acpmux stops listing it, so a refused archive keeps it.
    public func archive(_ id: String) { state.archived.insert(id) }

    /// Undoes `archive` when acpmux refused it, so the chat is not hidden here only.
    public func unarchive(_ id: String) { state.archived.remove(id) }

    public func setCollapsed(_ collapsed: Bool) { state.collapsed = collapsed }

    public func setFilter(_ filter: SidebarPriorityFilter) { state.filter = filter }

    /// Opens or folds the Archived fold.
    public func setArchivedOpen(_ open: Bool) { state.archivedOpen = open }

    /// The person dragged `id` in the Priority view, which now shows `order`: it keeps that place,
    /// and each chat dragged before keeps the place it shows at now. `moved` are other chats whose
    /// places the drag changed (the rows a filter showed, which trade the slots they held): they keep
    /// theirs too, so the ranking puts them back where the drag left them.
    public func place(_ id: String, in order: [String], moved: Set<String> = []) {
        var placed = state.placed
        for (index, other) in order.enumerated() where other == id || moved.contains(other) || placed[other] != nil {
            placed[other] = index
        }
        state.placed = placed
    }

    /// Drops the marks of sessions acpmux no longer lists, so the saved marks stay small.
    public func prune(keeping ids: Set<String>) {
        var next = state
        next.pinned.formIntersection(ids)
        next.archived.formIntersection(ids)
        next.read = next.read.filter { ids.contains($0.key) }
        next.snoozed = next.snoozed.filter { ids.contains($0.key) }
        next.placed = next.placed.filter { ids.contains($0.key) }
        if next != state { state = next }
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
