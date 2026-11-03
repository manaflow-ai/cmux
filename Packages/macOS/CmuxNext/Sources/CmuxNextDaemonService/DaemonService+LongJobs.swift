import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextWakeups

/// This machine's long jobs (plans/cmux-next/long-jobs-DESIGN.md): while the local owner restores,
/// the jobs its launcher heard of (`server ensure` progress lines, `long-jobs.json`); once connected,
/// the daemon's own list (`jobs-list` at connect, then every `jobs-changed`), when it serves `long_jobs`.
extension DaemonService {
    /// The jobs to show for this machine now, each stamped with the machine.
    public var jobs: [LongJob] {
        let listed = startup.isRestoring ? startup.restoringJobs
            : startup == .connected ? reconnectRestoringJobs ?? connectedJobs : []
        return listed.map { job in
            var job = job
            job.machine = machineID
            return job
        }
    }

    /// Follows the local owner's restore reports: each one is the owner saying it is alive and restoring,
    /// so startup reads `.restoring` with its jobs (not "connecting" and, past the deadline, not
    /// "unavailable"). A permanent failure or a connection keeps its state.
    func followRestoreProgress(_ progress: OwnerRestoreProgress) {
        restoreProgress = progress
        progress.observe { [weak self] _ in
            // task-owner: one main-actor hop per progress line (one every few seconds); it reads the latest report.
            Task { @MainActor [weak self] in self?.noteRestoreProgress() }
        }
    }

    /// One restore report on the main actor. Before the first connection it moves startup to `.restoring`; after one
    /// (its connection down, the owner restoring again) its jobs show as this machine's (``reconnectRestoringJobs``).
    /// Nothing after the service stopped (`shutdownConnection`), nothing a failure already judged, and after a stall
    /// only progress past it.
    func noteRestoreProgress() {
        guard isStarting, let report = restoreProgress?.current, report.sequence > restoreReportsJudged else { return }
        restoreReportsSeen += 1
        if startup == .connected {
            if case .connected = store.connectionState { return }
            if reconnectRestoringJobs != report.jobs { reconnectRestoringJobs = report.jobs }
            return
        }
        if case .unavailable(let error) = startup, DaemonStartup.shared.isPermanent(error) { return }
        if let stall = restoreStall {
            guard report.isProgress(past: stall) else { return }
            restoreStall = nil
        }
        if startup != .restoring(report.jobs) { startup = .restoring(report.jobs) }
        store.clearFailure()
    }

    /// Follows `jobs-changed` and the store's connection (once per service): each connect, a reconnect after a
    /// drop too, lists the daemon's jobs again (`jobs-list`, when it serves `long_jobs`); each drop clears them.
    /// A `jobs-list` reply is dropped when a `jobs-changed` came after it was sent (the event is newer).
    func followLongJobs() {
        if longJobsSubscription == nil {
            longJobsSubscription = store.sideEvents.subscribe { [weak self] event in
                guard let self, case .longJobsChanged(let jobs) = event else { return }
                longJobEvents += 1
                if jobs != connectedJobs { connectedJobs = jobs }
            }
        }
        guard longJobsConnection == nil else { return }
        let store = store
        // task-owner: cancelled with the connection (`detachConnection`); event-driven (Observation of the store's connection)
        longJobsConnection = Task { [weak self] in
            for await state in ObservationStream({ store.connectionState }) {
                guard let self else { return }
                guard case .connected(let identity) = state else {
                    if !connectedJobs.isEmpty { connectedJobs = [] }
                    continue
                }
                // Connected again: the restore that a reconnect waited for is over.
                if reconnectRestoringJobs != nil { reconnectRestoringJobs = nil }
                guard identity.supports(DaemonCapability.longJobs.rawValue), let connection else { continue }
                let sent = longJobEvents
                let reply = try? await connection.request(JobsListRequest())
                guard let reply, self.connection === connection, longJobEvents == sent else { continue }
                if reply.jobs != connectedJobs { connectedJobs = reply.jobs }
            }
        }
    }
}
