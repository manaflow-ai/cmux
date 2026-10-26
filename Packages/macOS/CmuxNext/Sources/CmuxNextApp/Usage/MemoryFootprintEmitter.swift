import CmuxNextCompat
import CmuxNextMemory
import CmuxNextWakeups

/// Samples the app's and the renderers' footprints into ``MemoryHistograms`` once per interval of
/// awake time (an hour by default), whatever the pressure level and however often `debug.memory` is
/// read, so `app_pmf_mb` and `renderer_pmf_mb` describe the session and not its pressure changes or
/// its readers. Chrome samples them the same way: `ChromeMetricsServiceClient::CollectFinalHistograms`
/// (chrome/browser/metrics/chrome_metrics_service_client.cc) runs `ProcessMemoryMetricsEmitter` once
/// per periodic metrics log, never on a memory pressure change or a `chrome://memory-internals` read.
///
/// One ``DemandTimer`` deadline per interval, on the suspending clock (hours while the Mac sleeps are
/// not hours, as in ``MemoryHistograms``). Each sample reads the live WebContent PIDs on the main actor
/// (O(live web views)), reads the footprints off it, and records two bucket counts back on it.
@MainActor
final class MemoryFootprintEmitter {
    /// Reads the footprints of the app, its Chromium helpers and the given WebContent processes, off the main actor.
    typealias Sampler = @concurrent @Sendable ([Int32]) async -> MemoryDiagnosticsProcesses

    private let histograms: MemoryHistograms
    private let webContentPIDs: @MainActor () -> [Int32]
    private let sample: Sampler
    private let interval: Duration
    private let timer: DemandTimer
    /// Between ``start()`` and ``stop()``.
    private var running = false

    /// - Parameters:
    ///   - histograms: The histograms the samples go in.
    ///   - webContentPIDs: The live WebContent processes, read on the main actor.
    ///   - sample: Reads the footprints; the app's processes by default.
    ///   - interval: The time between samples; one histogram hour by default.
    ///   - timer: The deadline; on the suspending clock by default (tests pass a manual clock).
    init(histograms: MemoryHistograms,
         webContentPIDs: @escaping @MainActor () -> [Int32],
         sample: @escaping Sampler = { await AppMemoryModel.processes(webContentPIDs: $0) },
         interval: Duration = MemoryHistograms.hour,
         timer: DemandTimer = DemandTimer(owner: "MemoryFootprintEmitter", clock: SuspendingClock())) {
        self.histograms = histograms
        self.webContentPIDs = webContentPIDs
        self.sample = sample
        self.interval = interval
        self.timer = timer
    }

    /// Arms the first sample one interval from now; a second call while armed changes nothing.
    func start() {
        running = true
        timer.scheduleIfIdle(after: interval) { @MainActor [weak self] in await self?.emit() }
    }

    /// Stops sampling.
    func stop() {
        running = false
        timer.cancel()
    }

    /// Records one sample, then arms the next unless ``stop()`` came meanwhile.
    private func emit() async {
        let processes = await sample(webContentPIDs())
        guard running else { return }
        histograms.recordFootprints(processes)
        start()
    }
}
