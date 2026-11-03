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
        guard let report = restoreProgress?.current, startup != .connected else { return }
        if case .unavailable(let error) = startup, DaemonStartup.shared.isPermanent(error) { return }
        if startup != .restoring(report.jobs) { startup = .restoring(report.jobs) }
        store.clearFailure()
    }

    /// Reads the daemon's jobs after a handshake and follows `jobs-changed` (once per service).
    func listLongJobs(_ connection: DaemonConnection, identity: DaemonIdentity) {
        if longJobsSubscription == nil {
            longJobsSubscription = store.sideEvents.subscribe { [weak self] event in
                guard let self, case .longJobsChanged(let jobs) = event, jobs != connectedJobs else { return }
                connectedJobs = jobs
            }
        }
        if !connectedJobs.isEmpty { connectedJobs = [] }
        guard identity.supports(DaemonCapability.longJobs.rawValue) else { return }
        // task-owner: one request with the control deadline; a failure leaves the list to the next event.
        Task { [weak self, weak connection] in
            guard let connection, let reply = try? await connection.request(JobsListRequest()) else { return }
            guard let self, self.connection === connection else { return }
            if reply.jobs != connectedJobs { connectedJobs = reply.jobs }
        }
    }
}
