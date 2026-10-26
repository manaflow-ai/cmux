import CmuxNextMetrics
import CmuxNextWakeups

/// Launch work that waits until the first window's first frame is committed,
/// so it never delays that frame (perf-launch-memory): the updater, SSH and
/// server-reach starts, and the warm-ups for later tabs.
///
/// `AppDelegate` calls ``open()`` from the first window's `CATransaction`
/// completion. A launch that shows no window (an agent launch, a daemon that
/// never answers) still opens it after `backstop`, so the work always runs.
///
/// The first committed frame also records `launch.first_frame.<temperature>`
/// (task 058), once, even when the backstop opened the gate earlier: a slow
/// cold launch is the sample that matters most. A backstop opening is not a
/// frame and records nothing, as Chrome records first paint only for a
/// window that painted (components/startup_metric_utils/browser/startup_metric_utils.cc,
/// `RecordFirstWebContentsNonEmptyPaint` and `UmaHistogramWithTemperature`).
@MainActor
final class FirstFrameGate {
    private var waiters: [@MainActor () -> Void] = []
    private(set) var isOpen = false
    /// Whether the first frame was committed (and its launch sample recorded).
    private(set) var frameCommitted = false
    private let backstop: DemandTimer
    private let launchMetric: LaunchFirstFrameMetric

    /// - Parameters:
    ///   - backstop: The deadline that opens the gate when no frame comes;
    ///     tests inject a manual clock.
    ///   - launchMetric: Measures and records the first frame's launch
    ///     sample; tests inject fixed values and a recording spy.
    init(backstop: DemandTimer = DemandTimer(owner: "FirstFrameGate.backstop"),
         launchMetric: LaunchFirstFrameMetric = .live()) {
        self.backstop = backstop
        self.launchMetric = launchMetric
    }

    /// Runs `work` once the gate is open: at once when it already is, else in
    /// the order the work was added.
    func whenOpen(_ work: @escaping @MainActor () -> Void) {
        if isOpen { work() } else { waiters.append(work) }
    }

    /// The first window's first frame was committed: records the launch
    /// sample (first call only), then opens the gate.
    func open() {
        if !frameCommitted {
            frameCommitted = true
            launchMetric.recordFirstFrame()
        }
        openGate()
    }

    /// Opens the gate after `delay` unless a frame opened it first.
    func armBackstop(after delay: Duration) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in self?.openGate() }
    }

    /// Opens the gate (first call only) and runs the waiting work.
    private func openGate() {
        guard !isOpen else { return }
        isOpen = true
        backstop.cancel()
        let waiting = waiters
        waiters.removeAll()
        for work in waiting { work() }
    }
}
