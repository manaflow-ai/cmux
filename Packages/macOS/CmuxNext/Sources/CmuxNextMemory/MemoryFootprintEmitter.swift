public import CmuxNextWakeups

/// Samples the app's and the renderers' footprints into ``MemoryHistograms`` once per interval of
/// awake time (an hour by default), whatever the pressure level and however often `debug.memory` is
/// read, so `app_pmf_mb` and `renderer_pmf_mb` describe the session and not its pressure changes or
/// its readers. Chrome samples them the same way: `ChromeMetricsServiceClient::CollectFinalHistograms`
/// (chrome/browser/metrics/chrome_metrics_service_client.cc) runs `ProcessMemoryMetricsEmitter` once
/// per periodic metrics log, never on a memory pressure change or a `chrome://memory-internals` read.
///
/// One ``MainDeadline`` per interval, in the `background` class: it wakes on uptime, which stops while the Mac
/// sleeps (hours asleep are not hours, as in ``MemoryHistograms``). Each sample reads the live WebContent PIDs
/// on the main actor (the owner's cheap read, no session walk), reads the footprints off it in a nonisolated
/// task, and records two bucket counts back on it as one `background` task.
@MainActor
public final class MemoryFootprintEmitter {
    /// Reads the footprints of the app, its Chromium helpers and the given WebContent processes, off the main actor.
    public typealias Sampler = @concurrent @Sendable ([Int32]) async -> MemoryDiagnosticsProcesses

    private let histograms: MemoryHistograms
    private let webContentPIDs: @MainActor () -> [Int32]
    private let sample: Sampler
    private let interval: Duration
    private let deadline: MainDeadline
    private let mainWork: MainWorkScheduler
    /// Between ``start()`` and ``stop()``.
    private var running = false
    /// The footprint read in flight; its record arms the next deadline.
    private var sampling: Task<Void, Never>?

    /// - Parameters:
    ///   - histograms: The histograms the samples go in.
    ///   - webContentPIDs: The live WebContent processes, read on the main actor.
    ///   - sample: Reads the footprints, off the main actor.
    ///   - interval: The time between samples; one histogram hour by default.
    ///   - deadlines: The app's one deadline scheduler (tests pass a rig's).
    public init(histograms: MemoryHistograms,
                webContentPIDs: @escaping @MainActor () -> [Int32],
                sample: @escaping Sampler,
                interval: Duration = MemoryHistograms.hour,
                deadlines: MainDeadlineScheduler) {
        self.histograms = histograms
        self.webContentPIDs = webContentPIDs
        self.sample = sample
        self.interval = interval
        deadline = MainDeadline(owner: "MemoryFootprintEmitter", workClass: .background, scheduler: deadlines)
        mainWork = deadlines.work
    }

    /// Arms the next sample one interval from now; a call while one is armed or being read changes nothing.
    public func start() {
        running = true
        guard sampling == nil else { return }
        deadline.scheduleIfIdle(after: interval) { [weak self] in self?.emit() }
    }

    /// Stops sampling; a sample being read is not recorded.
    public func stop() {
        running = false
        deadline.cancel()
    }

    /// Reads one sample off the main actor; ``record(_:)`` takes it back.
    private func emit() {
        let pids = webContentPIDs(), sample = self.sample, mainWork = self.mainWork
        // task-owner: sampling; one per interval, it ends with its record
        sampling = Task { @concurrent [weak self] in
            let processes = await sample(pids)
            await mainWork.apply(.background, owner: "MemoryFootprintEmitter.record") { [weak self] () -> Void in
                self?.record(processes)
            }
        }
    }

    /// Records one sample, then arms the next unless ``stop()`` came meanwhile.
    private func record(_ processes: MemoryDiagnosticsProcesses) {
        sampling = nil
        guard running else { return }
        histograms.recordFootprints(processes)
        start()
    }
}
