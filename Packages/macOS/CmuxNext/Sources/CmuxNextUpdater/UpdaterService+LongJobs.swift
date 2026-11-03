import CmuxNextCompat
public import CmuxNextWakeups

/// The app update's slow steps as long jobs (plans/cmux-next/long-jobs-DESIGN.md): the download
/// and unpack while the flow shows `downloading`, and the install while it shows `installing`
/// (quitting then interrupts it). One job per step, ended when the phase moves on.
extension UpdaterService {
    /// Registers this updater's download and install in `jobs` for as long as the app runs.
    public func trackLongJobs(in jobs: LongJobs) {
        let tracker = UpdateLongJobs()
        // task-owner: lives as long as the app's services; event-driven (Observation of the update flow's phase)
        Task { [weak self, weak jobs] in
            for await phase in ObservationStream({ [weak self] in self?.flow.phase ?? .hidden }) {
                guard self != nil, let jobs else { return }
                tracker.apply(phase, jobs: jobs)
            }
        }
    }
}

/// The download and install jobs of one updater (``UpdaterService/trackLongJobs(in:)``).
@MainActor
final class UpdateLongJobs {
    private var download: LongJobHandle?
    private var install: LongJobHandle?

    func apply(_ phase: UpdateIndicatorPhase, jobs: LongJobs) {
        switch phase {
        case .downloading(let transfer):
            let handle = download ?? jobs.begin(kind: LongJob.updateDownloadKind)
            download = handle
            if let fraction = transfer.fraction { handle.progress(fraction: fraction, detail: transfer.bytesText) }
        case .installing:
            endDownload()
            if install == nil { install = jobs.begin(kind: LongJob.updateInstallKind, blocks: [.quit]) }
        case .hidden, .checking, .available, .ready, .note:
            endDownload()
            install?.end()
            install = nil
        }
    }

    private func endDownload() {
        download?.end()
        download = nil
    }
}
