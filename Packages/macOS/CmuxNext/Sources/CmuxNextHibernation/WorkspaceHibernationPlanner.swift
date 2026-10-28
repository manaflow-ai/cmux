public import CmuxNextCompat
public import CmuxNextSettings
public import Foundation

/// Which idle workspaces leave memory, and when to look again (plans/cmux-next/workspace-hibernation-DESIGN.md).
///
/// Pure: the App gathers one ``Candidate`` per workspace it holds anything for, reads the clock once,
/// and hibernates ``Plan/due``. A workspace never hibernates while it is shown, pinned, running a
/// command or an agent turn, waiting on the person, kept awake by the person, or already hibernated.
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

        /// - Parameters:
        ///   - enabled: whether workspaces hibernate on their own (default on).
        ///   - idleMinutes: the idle time at normal pressure (default 60).
        public init(enabled: Bool = true, idleMinutes: Double = 60) {
            self.enabled = enabled
            self.idleMinutes = idleMinutes
        }

        /// The policy cmux.json's `workspaces.hibernation.*` sets; nil (no settings yet) takes the defaults.
        public init(_ settings: WorkspaceHibernationSettings?) {
            let settings = settings ?? WorkspaceHibernationSettings()
            self.init(enabled: settings.enabled, idleMinutes: settings.idleMinutes)
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

        /// Every flag defaults to false: an idle, unpinned, awake workspace.
        public init(workspace: String, lastActive: Date?, shown: Bool = false, pinned: Bool = false, running: Bool = false,
                    needsAttention: Bool = false, keptAwake: Bool = false, hibernated: Bool = false) {
            self.workspace = workspace
            self.lastActive = lastActive
            self.shown = shown
            self.pinned = pinned
            self.running = running
            self.needsAttention = needsAttention
            self.keptAwake = keptAwake
            self.hibernated = hibernated
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
    public func idleSeconds(_ policy: Policy, pressure: MemoryPressureLevel) -> TimeInterval? {
        nil // red: the policy lands in the next commit
    }

    /// The plan for `candidates` at `now`.
    public func plan(_ candidates: [Candidate], policy: Policy, pressure: MemoryPressureLevel, now: Date) -> Plan {
        Plan() // red: the policy lands in the next commit
    }
}
