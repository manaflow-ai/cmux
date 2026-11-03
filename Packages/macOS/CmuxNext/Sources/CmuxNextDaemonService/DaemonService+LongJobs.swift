import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextWakeups

/// This machine's long jobs (plans/cmux-next/long-jobs-DESIGN.md): while the local owner restores,
/// the jobs its launcher heard of (`server ensure` progress lines, `long-jobs.json`); once connected,
/// the daemon's own list (`jobs-list` at connect, then every `jobs-changed`), when it serves `long_jobs`.
extension DaemonService {
    /// The jobs to show for this machine now, each stamped with the machine.
    public var jobs: [LongJob] {
        let listed = startup.isRestoring ? startup.restoringJobs : (startup == .connected ? connectedJobs : [])
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

    func noteRestoreProgress() {
        guard let report = restoreProgress?.current, startup != .connected, report.sequence > restoreReportsJudged else { return }
        if case .unavailable(let error) = startup, DaemonStartup.shared.isPermanent(error) { return }
        if let mark = restoreStallMark {
            guard let latest = report.lastJobUpdateMs, latest > mark else { return }
            restoreStallMark = nil
        }
        if startup != .restoring(report.jobs) { startup = .restoring(report.jobs) }
        store.clearFailure()
    }

    /// Follows `jobs-changed` and the store's connection (once per service): each connect, a reconnect after a
    /// drop too, lists the daemon's jobs again (`jobs-list`, when it serves `long_jobs`); each drop clears them.
    func followLongJobs() {
        if longJobsSubscription == nil {
            longJobsSubscription = store.sideEvents.subscribe { [weak self] event in
                guard let self, case .longJobsChanged(let jobs) = event, jobs != connectedJobs else { return }
                connectedJobs = jobs
            }
        }
        guard longJobsConnection == nil else { return }
        let store = store
        // task-owner: lives as long as the service; event-driven (Observation of the store's connection state)
        longJobsConnection = Task { [weak self] in
            for await state in ObservationStream({ store.connectionState }) {
                guard let self else { return }
                guard case .connected(let identity) = state else {
                    if !connectedJobs.isEmpty { connectedJobs = [] }
                    continue
                }
                guard identity.supports(DaemonCapability.longJobs.rawValue), let connection else { continue }
                let reply = try? await connection.request(JobsListRequest())
                // A `jobs-changed` that came meanwhile is newer than this reply.
                if let reply, self.connection === connection, reply.jobs != connectedJobs { connectedJobs = reply.jobs }
            }
        }
    }
}
