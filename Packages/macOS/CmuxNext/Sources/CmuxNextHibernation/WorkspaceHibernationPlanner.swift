public import CmuxNextCompat
public import CmuxNextSettings
public import Foundation

/// Which idle workspaces leave memory, and when to look again (plans/cmux-next/workspace-hibernation-DESIGN.md).
///
/// Pure: the App gathers one ``Candidate`` per workspace it holds anything for, reads the clock once,
/// and hibernates ``Plan/due``. A workspace never hibernates while it is shown, pinned, running a
/// command or an agent turn, waiting on the person, kept awake by the person, or already hibernated.
/// A workspace of a space no window shows (``Candidate/inHiddenSpace``) waits the shorter
/// ``Policy/hiddenSpaceIdleMinutes`` instead (leo-workspace design/spaces.md, "Hibernation and the perf plan").
///
/// ```swift
/// let plan = WorkspaceHibernationPlanner().plan(candidates, policy: .init(idleMinutes: 60), pressure: .normal, now: Date())
/// plan.due.forEach(host.hibernate)
/// ```
public nonisolated struct WorkspaceHibernationPlanner: Sendable {
    /// Creates a planner (it holds no state).
    public init() {}

    /// The settings the planner reads (`workspaces.hibernation.*`).
    public nonisolated struct Policy: Equatable, Sendable {
        /// False: nothing hibernates on its own (Hibernate Workspace still works).
        public var enabled: Bool
        /// Minutes a workspace stays idle before it hibernates at normal memory pressure.
        public var idleMinutes: Double
        /// Minutes a workspace of a space no window shows stays idle before it hibernates (the shorter
        /// of this and ``idleMinutes`` applies).
        public var hiddenSpaceIdleMinutes: Double

        /// - Parameters:
        ///   - enabled: whether workspaces hibernate on their own (default on).
        ///   - idleMinutes: the idle time at normal pressure (default 60).
        ///   - hiddenSpaceIdleMinutes: the idle time of a hidden space's workspace (default the setting's).
        public init(enabled: Bool = true, idleMinutes: Double = 60,
                    hiddenSpaceIdleMinutes: Double = WorkspaceHibernationSettings.hiddenSpaceMinutesDefault) {
            self.enabled = enabled
            self.idleMinutes = idleMinutes
            self.hiddenSpaceIdleMinutes = hiddenSpaceIdleMinutes
        }

        /// The policy cmux.json's `workspaces.hibernation.*` sets; nil (no settings yet) takes the defaults.
        public init(_ settings: WorkspaceHibernationSettings?) {
            let settings = settings ?? WorkspaceHibernationSettings()
            self.init(enabled: settings.enabled, idleMinutes: settings.idleMinutes, hiddenSpaceIdleMinutes: settings.hiddenSpaceMinutes)
        }
    }

    /// One workspace and what keeps it awake.
    public nonisolated struct Candidate: Hashable, Sendable {
        /// The workspace's id.
        public var workspace: String
        /// The newest sign of use: last shown in a window, output, an agent update, a notification.
        /// Nil: never seen this run, which counts as used at the first pass (never idle on arrival).
        public var lastActive: Date?
        /// Shown in a window now (a `sidebar.multiView` companion and the workspace under a top page count).
        public var shown: Bool
        /// Pinned in the sidebar.
        public var pinned: Bool
        /// A command or an agent turn runs in one of its tabs.
        public var running: Bool
        /// It waits on the person (an agent question, an error).
        public var needsAttention: Bool
        /// The person chose Keep Workspace Awake for it.
        public var keptAwake: Bool
        /// Already hibernated (nothing of it is in memory).
        public var hibernated: Bool
        /// No window shows any space it is in: it waits ``Policy/hiddenSpaceIdleMinutes``.
        public var inHiddenSpace: Bool

        /// Every flag defaults to false: an idle, unpinned, awake workspace of a shown space.
        public init(workspace: String, lastActive: Date?, shown: Bool = false, pinned: Bool = false, running: Bool = false,
                    needsAttention: Bool = false, keptAwake: Bool = false, hibernated: Bool = false, inHiddenSpace: Bool = false) {
            self.workspace = workspace
            self.lastActive = lastActive
            self.shown = shown
            self.pinned = pinned
            self.running = running
            self.needsAttention = needsAttention
            self.keptAwake = keptAwake
            self.hibernated = hibernated
            self.inHiddenSpace = inHiddenSpace
        }

        /// Whether anything keeps it awake whatever its age.
        public var isKept: Bool { shown || pinned || running || needsAttention || keptAwake || hibernated }
    }

    /// What is due now, and when the next one comes due.
    public nonisolated struct Plan: Equatable, Sendable {
        /// The workspaces to hibernate now, idlest first.
        public var due: [String]
        /// When the next kept-for-age workspace comes due; nil when none will without a change.
        public var nextCheck: Date?

        /// - Parameters:
        ///   - due: the workspaces to hibernate now.
        ///   - nextCheck: when to plan again.
        public init(due: [String] = [], nextCheck: Date? = nil) {
            self.due = due
            self.nextCheck = nextCheck
        }
    }

    /// Never look again sooner than this after a pass: a burst of changes stays one pass a minute.
    public static let minimumRecheck: TimeInterval = 60
    /// The idle time under warning memory pressure, when the setting is longer.
    public static let warningIdle: TimeInterval = 10 * 60
    /// The idle time under critical memory pressure: only what was just hidden stays.
    public static let criticalIdle: TimeInterval = 60

    /// Seconds a workspace must stay idle under `pressure`, or nil when nothing hibernates on its own.
    /// `hiddenSpace`: the workspace's space is shown in no window, so the shorter hidden-space setting applies.
    public func idleSeconds(_ policy: Policy, pressure: MemoryPressureLevel, hiddenSpace: Bool = false) -> TimeInterval? {
        guard policy.enabled else { return nil }
        let minutes = hiddenSpace ? min(policy.idleMinutes, policy.hiddenSpaceIdleMinutes) : policy.idleMinutes
        let normal = max(minutes, 1) * 60
        return switch pressure {
        case .normal: normal
        case .warning: min(normal, Self.warningIdle)
        case .critical: min(normal, Self.criticalIdle)
        }
    }

    /// The plan for `candidates` at `now`.
    public func plan(_ candidates: [Candidate], policy: Policy, pressure: MemoryPressureLevel, now: Date) -> Plan {
        guard let idle = idleSeconds(policy, pressure: pressure),
              let hiddenIdle = idleSeconds(policy, pressure: pressure, hiddenSpace: true) else { return Plan() }
        var due: [(String, TimeInterval)] = []
        var next: Date?
        for candidate in candidates where !candidate.isKept {
            guard let lastActive = candidate.lastActive else { continue }
            let deadline = lastActive.addingTimeInterval(candidate.inHiddenSpace ? hiddenIdle : idle)
            if deadline <= now {
                due.append((candidate.workspace, now.timeIntervalSince(lastActive)))
            } else if next.map({ deadline < $0 }) ?? true {
                next = deadline
            }
        }
        let floor = now.addingTimeInterval(Self.minimumRecheck)
        return Plan(due: due.sorted { $0.1 > $1.1 }.map(\.0), nextCheck: next.map { max($0, floor) })
    }
}
