public import CmuxNextCompat
public import Foundation
import os

/// What workspace hibernation reads from the App and asks it to do (plans/cmux-next/workspace-hibernation-DESIGN.md):
/// the composition root conforms with one-line forwards, tests pass a fake.
@MainActor
public protocol WorkspaceHibernationHost: AnyObject {
    /// Every workspace this app holds memory for now (mounted content, a page, a terminal surface).
    func hibernationResidents() -> [WorkspaceHibernationResident]
    /// The workspaces shown in a window now (with `sidebar.multiView` companions and the workspace under a top page).
    func hibernationShownWorkspaces() -> Set<String>
    /// `workspaces.hibernation.*`.
    func hibernationPolicy() -> WorkspaceHibernationPlanner.Policy
    /// Frees `workspace`'s memory: unmounts it in every window, destroys its terminal surfaces,
    /// discards its pages and lets its chat pages go (each page's own checks may keep it).
    func hibernate(workspace: String)
}

/// The one-shot deadline the coordinator plans its next pass with (the App passes a `DemandTimer`;
/// tests pass a fake, so no test waits on a clock).
public nonisolated protocol WorkspaceHibernationDeadline: AnyObject, Sendable {
    /// True while a deadline is pending.
    var isScheduled: Bool { get }
    /// Runs `action` once after `delay`, replacing any pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void)
    /// Drops the pending deadline.
    func cancel()
}

/// One workspace the App holds memory for, and what keeps it awake.
public nonisolated struct WorkspaceHibernationResident: Hashable, Sendable {
    /// The workspace's id.
    public var workspace: String
    /// The newest output, agent update or notification in it.
    public var lastActivity: Date?
    /// Pinned in the sidebar.
    public var pinned: Bool
    /// A command or an agent turn runs in one of its tabs.
    public var running: Bool
    /// An agent waits on the person, or it shows an error.
    public var needsAttention: Bool
    /// No window shows any space it is in (its space is hidden), so it hibernates on the shorter clock.
    public var inHiddenSpace: Bool

    /// Every flag defaults to false.
    public init(workspace: String, lastActivity: Date? = nil, pinned: Bool = false, running: Bool = false, needsAttention: Bool = false,
                inHiddenSpace: Bool = false) {
        self.workspace = workspace
        self.lastActivity = lastActivity
        self.pinned = pinned
        self.running = running
        self.needsAttention = needsAttention
        self.inHiddenSpace = inHiddenSpace
    }
}

/// Why Hibernate Workspace did nothing.
public nonisolated enum WorkspaceHibernationRefusal: Error, Equatable {
    /// It is shown in a window.
    case shown
}

/// Hibernates idle workspaces (plans/cmux-next/workspace-hibernation-DESIGN.md): one deadline for the
/// soonest workspace to come due, a pass on a show or hide, a setting change or a pressure change.
/// No polling. Knows when each workspace was last shown this run; the host knows the rest.
///
/// ```swift
/// let hibernation = WorkspaceHibernation(host: services, keepAwake: WorkspaceKeepAwakeStore(defaults: .standard),
///                                        deadline: DemandTimer(owner: "workspace-hibernation"))
/// hibernation.start()
/// ```
@MainActor
public final class WorkspaceHibernation {
    private let host: any WorkspaceHibernationHost
    /// The person's Keep Awake set.
    public let keepAwake: WorkspaceKeepAwakeStore
    private let now: @MainActor () -> Date
    private let deadline: any WorkspaceHibernationDeadline
    private let planner = WorkspaceHibernationPlanner()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    /// When each workspace was last shown, or first seen (never idle on arrival).
    private var lastShown: [String: Date] = [:]
    private var shown: Set<String> = []
    /// Hibernated and not shown since.
    public private(set) var hibernated: Set<String> = []
    /// The memory pressure it plans for.
    public private(set) var pressure: MemoryPressureLevel = .normal
    private var follows: [Task<Void, Never>] = []
    /// How many workspaces it hibernated this run (`debug.surfaces`).
    public private(set) var hibernatedCount = 0

    /// The first pass after launch: nothing is resident yet, and a launch is no time to evict.
    public static let launchDelay: Duration = .seconds(60)

    /// - Parameters:
    ///   - host: the App's owners.
    ///   - keepAwake: the person's Keep Awake set.
    ///   - deadline: the one-shot timer of the next pass.
    ///   - now: the wall clock idle times are measured on.
    public init(host: any WorkspaceHibernationHost, keepAwake: WorkspaceKeepAwakeStore, deadline: any WorkspaceHibernationDeadline,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.host = host
        self.keepAwake = keepAwake
        self.deadline = deadline
        self.now = now
    }

    /// Follows the shown workspaces and the setting, and schedules the first pass.
    public func start() {
        // task-owner: the shown-workspaces follow; cancelled in stop()
        follows.append(Task { @MainActor [weak self] in
            for await shown in ObservationStream({ [weak self] in self?.host.hibernationShownWorkspaces() ?? [] }) {
                self?.noteShown(shown)
            }
        })
        // task-owner: the settings follow; cancelled in stop()
        follows.append(Task { @MainActor [weak self] in
            var first = true
            for await _ in ObservationStream({ [weak self] in self?.host.hibernationPolicy() ?? .init() }) {
                self?.schedulePass(after: first ? Self.launchDelay : .seconds(1))
                first = false
            }
        })
    }

    /// Stops following and drops the deadline.
    public func stop() {
        follows.forEach { $0.cancel() }
        follows = []
        deadline.cancel()
    }

    /// The shown workspaces changed: one that left starts its idle clock, one that came back is awake.
    /// One that left re-arms the deadline a minute out even when a later one is pending: a window that
    /// switched space may have hidden that space, whose workspaces wait the shorter hidden-space time,
    /// so the pending deadline (planned on the old shown set) can be too late. That pass re-plans it.
    public func noteShown(_ current: Set<String>) {
        let time = now()
        for id in shown.symmetricDifference(current) { lastShown[id] = time }
        for id in current { hibernated.remove(id) }
        let left = !shown.subtracting(current).isEmpty
        shown = current
        if left { schedulePass(after: .seconds(Int64(WorkspaceHibernationPlanner.minimumRecheck))) }
    }

    /// Memory pressure changed: a higher level shortens the idle time, so plan now.
    public func pressureDidChange(_ level: MemoryPressureLevel) {
        guard level != pressure else { return }
        pressure = level
        if level != .normal { pass() } else { schedulePass(after: .seconds(1)) }
    }

    /// Plans and hibernates what is due, then arms the deadline for the next one.
    public func pass() {
        let time = now()
        let residents = host.hibernationResidents()
        let live = Set(residents.map(\.workspace))
        let current = host.hibernationShownWorkspaces()
        if current != shown { noteShown(current) }
        // A workspace first seen now starts its clock now: nothing is idle on arrival.
        for resident in residents where lastShown[resident.workspace] == nil { lastShown[resident.workspace] = time }
        let candidates = residents.map { resident -> WorkspaceHibernationPlanner.Candidate in
            let seen = lastShown[resident.workspace] ?? time
            let active = [seen, resident.lastActivity].compactMap(\.self).max()
            return WorkspaceHibernationPlanner.Candidate(
                workspace: resident.workspace, lastActive: active, shown: shown.contains(resident.workspace),
                pinned: resident.pinned, running: resident.running, needsAttention: resident.needsAttention,
                keptAwake: keepAwake.contains(resident.workspace), hibernated: hibernated.contains(resident.workspace),
                inHiddenSpace: resident.inHiddenSpace)
        }
        // A hibernated workspace that holds nothing more stays hibernated until shown; one that is
        // gone (closed) is forgotten.
        let plan = planner.plan(candidates, policy: host.hibernationPolicy(), pressure: pressure, now: time)
        let hiddenSpace = Set(residents.filter(\.inHiddenSpace).map(\.workspace))
        for id in plan.due {
            hibernateNow(id, cause: pressure != .normal ? "memory-pressure=\(pressure.rawValue)" : hiddenSpace.contains(id) ? "hidden-space" : "idle")
        }
        lastShown = lastShown.filter { live.contains($0.key) || shown.contains($0.key) }
        if let next = plan.nextCheck {
            schedulePass(after: .milliseconds(Int64(max(next.timeIntervalSince(time), 1) * 1000)))
        } else {
            deadline.cancel()
        }
    }

    /// Hibernate Workspace (palette, CLI): hibernates `workspace` now, idle or not, unless it is shown.
    public func hibernateNow(_ workspace: String) throws(WorkspaceHibernationRefusal) {
        guard !host.hibernationShownWorkspaces().contains(workspace) else { throw .shown }
        hibernateNow(workspace, cause: "person")
    }

    /// Keep Workspace Awake: flips the person's opt-out and returns whether it is now kept awake.
    @discardableResult
    public func toggleKeepAwake(_ workspace: String) -> Bool {
        let kept = keepAwake.toggle(workspace)
        if !kept { schedulePass(after: .seconds(1)) }
        return kept
    }

    /// Whether `workspace` hibernated and was not shown since.
    public func isHibernated(_ workspace: String) -> Bool { hibernated.contains(workspace) }

    private func hibernateNow(_ workspace: String, cause: String) {
        host.hibernate(workspace: workspace)
        hibernated.insert(workspace)
        hibernatedCount += 1
        logger.notice("hibernated workspace \(workspace, privacy: .public) cause=\(cause, privacy: .public)")
    }

    private func schedulePass(after delay: Duration) {
        deadline.schedule(after: delay) { @MainActor [weak self] in self?.pass() }
    }
}
