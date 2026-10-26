public import Foundation

/// Which workspaces are idle enough to archive, and when to look again
/// (plans/cmux-next/auto-archive-DESIGN.md). Pure: the App gathers one ``Candidate`` per placed
/// workspace and the groups' rules, reads the clock once, and performs the ``Plan``. The planner
/// never archives anything that is pinned, shown in a window, running a command or an agent turn,
/// or asking for the person (unread, waiting, error), and never a workspace whose nearest group says
/// Never.
///
/// ```swift
/// let plan = AutoArchivePlanner().plan(candidates, rules: rules, policy: host.autoArchivePolicy(),
///                                      trigger: .background, now: clock.now)
/// store.setArchived(plan.due.map(\.item), archived: true, title: ...)
/// ```
public nonisolated struct AutoArchivePlanner: Sendable {
    public init() {}

    /// One placed workspace and what keeps it.
    public nonisolated struct Candidate: Hashable, Sendable {
        /// The sidebar document item that places it (what `archive` takes).
        public var item: String
        /// The workspace's id (for the toast's and card's names and the activity ledger).
        public var workspace: String
        /// The name the card lists.
        public var title: String
        /// The newest sign of use: shown, typed in, output, an agent update, a notification. Nil:
        /// never seen; the ledger records the first sight, so a workspace is never idle on arrival.
        public var lastActive: Date?
        /// Its group items, nearest first (the nearest group with a rule decides).
        public var groups: [String]
        /// Pinned (in Pinned or in its group): never archives.
        public var pinned: Bool
        /// Already archived: skipped.
        public var archived: Bool
        /// Shown in a window right now: counts as used now.
        public var shown: Bool
        /// A command or an agent turn runs in one of its tabs.
        public var running: Bool
        /// It asks for the person: unread, waiting for an answer, an error.
        public var needsAttention: Bool

        public init(item: String, workspace: String, title: String = "", lastActive: Date?, groups: [String] = [],
                    pinned: Bool = false, archived: Bool = false, shown: Bool = false, running: Bool = false,
                    needsAttention: Bool = false) {
            self.item = item
            self.workspace = workspace
            self.title = title
            self.lastActive = lastActive
            self.groups = groups
            self.pinned = pinned
            self.archived = archived
            self.shown = shown
            self.running = running
            self.needsAttention = needsAttention
        }
    }

    /// What asks for the plan.
    public nonisolated enum Trigger: Hashable, Sendable {
        /// The background pass (launch, a deadline, a setting change): obeys the style.
        case background
        /// Archive Idle Workspaces: the person asked, so it runs under every style, and uses the
        /// idle time even where the style would only suggest. A group's Never still keeps its members.
        case sweep
    }

    /// The result: what is due now, and when the next one comes due.
    public nonisolated struct Plan: Equatable, Sendable {
        /// The workspaces to archive (or suggest), idlest first.
        public var due: [Candidate]
        /// When the next kept-for-age workspace comes due; nil when none will without a change.
        public var nextCheck: Date?

        public init(due: [Candidate] = [], nextCheck: Date? = nil) {
            self.due = due
            self.nextCheck = nextCheck
        }
    }

    /// Never look again sooner than this after a pass: a burst of wakes stays one pass a minute.
    public static let minimumRecheck: TimeInterval = 60

    /// The plan for `candidates` at `now`. `rules` holds each group's own rule by item id.
    public func plan(_ candidates: [Candidate], rules: [String: SidebarDocAutoArchiveRule], policy: AutoArchivePolicy,
                     trigger: Trigger, now: Date) -> Plan {
        if trigger == .background, policy.style == .off || policy.style == .manual { return Plan() }
        var due: [(Candidate, TimeInterval)] = []
        var next: Date?
        for candidate in candidates where !candidate.archived && !candidate.pinned && !candidate.shown
            && !candidate.running && !candidate.needsAttention {
            guard let idle = idleSeconds(for: candidate, rules: rules, policy: policy, trigger: trigger),
                  let lastActive = candidate.lastActive else { continue }
            let deadline = lastActive.addingTimeInterval(idle)
            if deadline <= now {
                due.append((candidate, now.timeIntervalSince(lastActive)))
            } else if next.map({ deadline < $0 }) ?? true {
                next = deadline
            }
        }
        let floor = now.addingTimeInterval(Self.minimumRecheck)
        return Plan(due: due.sorted { $0.1 > $1.1 }.map(\.0), nextCheck: next.map { max($0, floor) })
    }

    /// Seconds `candidate` must stay idle, or nil when nothing archives it: the nearest group with a
    /// rule decides (Never: nil). Without one, the setting's days, except the Groups style, which only
    /// archives where a group set a rule (the person's sweep still uses the days).
    func idleSeconds(for candidate: Candidate, rules: [String: SidebarDocAutoArchiveRule], policy: AutoArchivePolicy,
                     trigger: Trigger) -> TimeInterval? {
        let ruled = trigger == .sweep || policy.style != .off
        if ruled, let rule = candidate.groups.lazy.compactMap({ rules[$0] }).first { return rule.idleSeconds }
        if trigger == .background, policy.style == .groups { return nil }
        return policy.idleSeconds
    }
}
