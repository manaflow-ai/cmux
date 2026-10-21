public import CmuxNextAgentActivity
public import CmuxNextSidebar
public import Foundation

/// Ranks every agent chat for the sidebar's Priority view by what needs the person: a permission
/// prompt or question first, then a result nobody has seen, then a failed or lost turn, then the
/// ones working, then idle. Within a tier pinned chats come first, then the most recent change.
/// acpmux decides each session's lane; this only orders them and applies the person's marks.
public nonisolated struct AgentPriorityRanking: Sendable {
    /// An idle chat with nothing unseen leaves the view after this long, unless pinned.
    public var idleHorizon: TimeInterval = 24 * 60 * 60

    public init() {}

    /// The rows in rank order: snoozed and archived chats left out, and idle ones older than
    /// `idleHorizon` unless pinned. `machine` is each row's machine tag (the lane's peer unless
    /// the caller names its machine).
    public func entries(_ lanes: [AgentActivityLane], marks: AgentPriorityMarks.State, now: Date,
                        machine: (AgentActivityLane) -> String? = { $0.peer }) -> [SidebarPriorityEntry] {
        let ranked = lanes.compactMap { lane -> (entry: SidebarPriorityEntry, tier: Int, since: Date)? in
            let stamp = AgentPriorityMarks.stamp(lane)
            guard !marks.archived.contains(lane.id), !marks.isSnoozed(lane.id, stamp: stamp, now: now) else { return nil }
            let read = marks.read[lane.id] == stamp
            let pinned = marks.pinned.contains(lane.id)
            let state = Self.state(lane, read: read)
            if state == .idle, !pinned, let since = lane.since, now.timeIntervalSince(since) > idleHorizon { return nil }
            let entry = SidebarPriorityEntry(id: lane.id, title: lane.title, project: lane.project, machine: machine(lane),
                                             preview: Self.preview(lane), state: state, unread: lane.unread && !read, pinned: pinned)
            return (entry, Self.tier(state), lane.since ?? .distantPast)
        }
        return ranked.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.entry.pinned != b.entry.pinned { return a.entry.pinned }
            if a.since != b.since { return a.since > b.since }
            return a.entry.id < b.entry.id
        }.map(\.entry)
    }

    /// When the rows next change with no lane or mark change: a snooze ends, or an idle chat passes
    /// `idleHorizon` and leaves. Nil when nothing is pending.
    public func nextChange(_ lanes: [AgentActivityLane], marks: AgentPriorityMarks.State, now: Date) -> Date? {
        let changes = lanes.compactMap { lane -> Date? in
            guard !marks.archived.contains(lane.id) else { return nil }
            let stamp = AgentPriorityMarks.stamp(lane)
            // A snooze on the chat's current state ends; one on an older state no longer applies.
            if let snooze = marks.snoozed[lane.id], snooze.stamp == stamp, snooze.until > now { return snooze.until }
            guard !marks.pinned.contains(lane.id), Self.state(lane, read: marks.read[lane.id] == stamp) == .idle else { return nil }
            return lane.since?.addingTimeInterval(idleHorizon)
        }
        return changes.filter { $0 > now }.min()
    }

    /// The chip a lane shows. Marking a finished, failed or lost chat read drops it to idle.
    static func state(_ lane: AgentActivityLane, read: Bool) -> SidebarPriorityEntry.State {
        switch lane.state {
        case .input: .needsYou
        case .working: .working(since: lane.since)
        case .failed: read ? .idle : .failed
        case .lost: read ? .idle : .lost
        case .idle: lane.unread && !read ? .done : .idle
        }
    }

    static func tier(_ state: SidebarPriorityEntry.State) -> Int {
        switch state {
        case .needsYou: 0
        case .done: 1
        case .failed, .lost: 2
        case .working: 3
        case .idle: 4
        }
    }

    /// The failed turn's error, else what the chat is doing or last said. Both come masked from acpmux.
    static func preview(_ lane: AgentActivityLane) -> String? {
        if lane.state == .failed || lane.state == .lost, let error = lane.error { return error }
        return lane.step
    }
}
