public import CmuxNextDaemon
public import CmuxNextWakeups

/// Follows every workspace's status entries of one store for the finished-run notices
/// (plans/cmux-next/status-indicators.md section 2): one observation of the workspace set, through
/// its revision (it moves only when a workspace comes or goes), and one observation and
/// ``FinishedStatusRunTracker`` per workspace, so a status change in one workspace (a script that
/// sets statuses in 50) costs that workspace only. The statuses come from `cmux status`, so every
/// observation flushes in the automation class.
///
/// It owns all of them: releasing it or ``cancel()`` stops every one, and nothing calls `changed`
/// after that. Each follower keeps its own store's watches, so two stores never share one.
@MainActor
public final class StatusRunFollower {
    /// One workspace's status changed: its tracker, to update with the status (the app posts the
    /// notices of the runs that finished).
    public typealias Changed = @MainActor (_ status: WorkspaceStatus?, _ tracker: inout FinishedStatusRunTracker) -> Void

    private let store: DaemonStore
    private let work: MainWorkScheduler
    private let changed: Changed
    private var membership: ServiceObservation<UInt64>?
    private var watches: [ObjectIdentifier: ServiceObservation<WorkspaceStatus?>] = [:]
    private var trackers: [ObjectIdentifier: FinishedStatusRunTracker] = [:]

    /// Starts following; the first pass reads every workspace's status before it returns (it learns
    /// the runs that are busy now).
    ///
    /// - Parameters:
    ///   - store: The store whose workspaces it follows.
    ///   - work: The app's main-thread scheduler.
    ///   - changed: Called with each workspace's new status and its tracker.
    public init(store: DaemonStore, work: MainWorkScheduler, changed: @escaping Changed) {
        self.store = store
        self.work = work
        self.changed = changed
        membership = ServiceObservation(.automation, owner: "notifications.status-runs.set", on: work) {
            store.workspaceSetRevision
        } apply: { [weak self] _ in
            self?.membershipChanged()
        }
    }

    /// The workspaces it watches now (tests).
    public var watchedCount: Int { watches.count }

    /// Stops the follower and every per-workspace observation. Idempotent.
    public func cancel() {
        membership?.cancel()
        membership = nil
        for watch in watches.values { watch.cancel() }
        watches = [:]
        trackers = [:]
    }

    /// A workspace came or went: the leavers' watches stop, each newcomer gets one.
    private func membershipChanged() {
        let listed = Dictionary(store.workspaces.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        for (id, watch) in watches where listed[id] == nil {
            watch.cancel()
            watches[id] = nil
            trackers[id] = nil
        }
        for (id, workspace) in listed where watches[id] == nil {
            // The watch's first apply reads the tracker, so the tracker comes first.
            trackers[id] = FinishedStatusRunTracker()
            watches[id] = ServiceObservation(.automation, owner: "notifications.status-runs.workspace", on: work) {
                workspace.status
            } apply: { [weak self] status in
                self?.statusChanged(id, status)
            }
        }
    }

    private func statusChanged(_ id: ObjectIdentifier, _ status: WorkspaceStatus?) {
        guard var tracker = trackers[id] else { return }
        changed(status, &tracker)
        trackers[id] = tracker
    }
}
