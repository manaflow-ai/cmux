public import CmuxNextAgentActivity
public import CmuxNextSidebar
public import Foundation

/// Ranks every agent chat for the sidebar's Priority view by what needs the person: a permission
/// prompt or question first, then a result nobody has seen, then a failed or lost turn, then Red
/// CI (a pull request of the chat's with failing checks), then the ones working, then idle. Within
/// a tier pinned chats come first, then the most recent change. A chat the person dragged shows
/// at the place they dropped it, the others ranked around it. acpmux decides each session's
/// lane and the session tree's pull request badge whose checks fail; this only orders them and
/// applies the person's marks. The sidebar rows' chip (`SidebarLaneStatus.chip`) reads the same
/// `state` and `tier`.
public nonisolated struct AgentPriorityRanking: Sendable {
    /// An idle chat with nothing unseen leaves the view after this long, unless pinned.
    public var idleHorizon: TimeInterval = 24 * 60 * 60

    public init() {}

    /// The chats Go to Next Agent Needing Input visits, in its order: of `waiting` (lanes the caller
    /// read from its waiting index), the ones still at a permission prompt or question and neither
    /// archived nor snoozed, pinned first, then the newest ask. The Priority view's needs-you tier
    /// in its order (a dragged row's place aside), built from those lanes alone: unseen results and
    /// failed chats never satisfy "Needs input", and nothing ranks the other chats.
    public static func needingInput(_ waiting: [AgentActivityLane], marks: AgentPriorityMarks.State, now: Date) -> [AgentActivityLane] {
        waiting.filter { lane in
            lane.state == .input && !marks.archived.contains(lane.id)
                && !marks.isSnoozed(lane.id, stamp: AgentPriorityMarks.stamp(lane), now: now)
        }.sorted { a, b in
            let pinnedA = marks.pinned.contains(a.id), pinnedB = marks.pinned.contains(b.id)
            if pinnedA != pinnedB { return pinnedA }
            let sinceA = a.since ?? .distantPast, sinceB = b.since ?? .distantPast
            if sinceA != sinceB { return sinceA > sinceB }
            return a.id < b.id
        }
    }

    /// The chat after `previous` in `ids` (``needingInput(_:marks:now:)``'s order), wrapping; the
    /// first when `previous` is nil or no longer waits; nil when none waits.
    public static func next(after previous: String?, in ids: [String]) -> String? {
        guard let first = ids.first else { return nil }
        guard let previous, let index = ids.firstIndex(of: previous) else { return first }
        return ids[(index + 1) % ids.count]
    }

    /// The rows in rank order: snoozed and archived chats left out, and idle ones older than
    /// `idleHorizon` unless pinned or dragged to a place. `failingChecks` are the ids of the chats
    /// with a pull request whose checks fail; `machine` is each row's machine tag (the lane's peer
    /// unless the caller names its machine).
    public func entries(_ lanes: [AgentActivityLane], marks: AgentPriorityMarks.State, now: Date,
                        failingChecks: Set<String> = [],
                        machine: (AgentActivityLane) -> String? = { $0.peer }) -> [SidebarPriorityEntry] {
        let ranked = lanes.compactMap { lane -> (entry: SidebarPriorityEntry, tier: Int, since: Date)? in
            let stamp = AgentPriorityMarks.stamp(lane)
            guard !marks.archived.contains(lane.id), !marks.isSnoozed(lane.id, stamp: stamp, now: now) else { return nil }
            let read = marks.read[lane.id] == stamp
            let pinned = marks.pinned.contains(lane.id)
            let state = Self.state(lane, read: read, failingChecks: failingChecks.contains(lane.id))
            let kept = pinned || marks.placed[lane.id] != nil
            if state == .idle, !kept, let since = lane.since, now.timeIntervalSince(since) > idleHorizon { return nil }
            let entry = SidebarPriorityEntry(id: lane.id, title: lane.title, project: lane.project, machine: machine(lane),
                                             preview: Self.preview(lane), state: state, unread: lane.unread && !read, pinned: pinned,
                                             brand: SidebarItemInfo.agentBrand(forHarness: lane.harness),
                                             agentColor: SidebarItemInfo.stableAgentColor(for: lane.id))
            return (entry, Self.tier(state), lane.since ?? .distantPast)
        }
        var rows = ranked.filter { marks.placed[$0.entry.id] == nil }.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.entry.pinned != b.entry.pinned { return a.entry.pinned }
            if a.since != b.since { return a.since > b.since }
            return a.entry.id < b.entry.id
        }.map(\.entry)
        // The dragged chats go back in where the person put them, the top place first.
        let placed = ranked.compactMap { row in marks.placed[row.entry.id].map { (row.entry, $0) } }
        for (entry, place) in placed.sorted(by: { ($0.1, $0.0.id) < ($1.1, $1.0.id) }) {
            rows.insert(entry, at: min(place, rows.count))
        }
        return rows
    }

    /// When the rows next change with no lane or mark change: a snooze ends, or an idle chat passes
    /// `idleHorizon` and leaves. Nil when nothing is pending.
    public func nextChange(_ lanes: [AgentActivityLane], marks: AgentPriorityMarks.State, now: Date,
                           failingChecks: Set<String> = []) -> Date? {
        let changes = lanes.compactMap { lane -> Date? in
            guard !marks.archived.contains(lane.id) else { return nil }
            let stamp = AgentPriorityMarks.stamp(lane)
            // A snooze on the chat's current state ends; one on an older state no longer applies.
            if let snooze = marks.snoozed[lane.id], snooze.stamp == stamp, snooze.until > now { return snooze.until }
            let state = Self.state(lane, read: marks.read[lane.id] == stamp, failingChecks: failingChecks.contains(lane.id))
            guard !marks.pinned.contains(lane.id), marks.placed[lane.id] == nil, state == .idle else { return nil }
            return lane.since?.addingTimeInterval(idleHorizon)
        }
        return changes.filter { $0 > now }.min()
    }

    /// The chip a lane shows: its turn's, unless `failingChecks` (a pull request of the chat's has
    /// failing checks) ranks higher, which it does over working and idle. Marking a finished,
    /// failed or lost chat read drops it to idle, or to Red CI while the checks still fail: a read
    /// mark does not hide them, a snooze does.
    static func state(_ lane: AgentActivityLane, read: Bool, failingChecks: Bool = false) -> SidebarPriorityEntry.State {
        let turn: SidebarPriorityEntry.State = switch lane.state {
        case .input: .needsYou
        case .working: .working(since: lane.since)
        case .failed: read ? .idle : .failed
        case .lost: read ? .idle : .lost
        case .idle: lane.unread && !read ? .done : .idle
        }
        return failingChecks && tier(.ciFailing) < tier(turn) ? .ciFailing : turn
    }

    static func tier(_ state: SidebarPriorityEntry.State) -> Int {
        switch state {
        case .needsYou: 0
        case .done: 1
        case .failed, .lost: 2
        case .ciFailing: 3
        case .working: 4
        case .idle: 5
        }
    }

    /// The failed turn's error, else what the chat is doing or last said. Both come masked from acpmux.
    static func preview(_ lane: AgentActivityLane) -> String? {
        if lane.state == .failed || lane.state == .lost, let error = lane.error { return error }
        return lane.step
    }
}
