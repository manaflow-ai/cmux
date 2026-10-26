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
/// (task 058) when the launch was not interrupted. A backstop opening
/// interrupts it: the launch showed no frame in time (an agent or daemon
/// launch), so a window the person opens later records nothing. Chrome drops
/// the sample the same way: `RecordFirstWebContentsNonEmptyPaint` returns
/// early unless `ShouldLogStartupHistogram()`, which is false once
/// `WasMainWindowStartupInterrupted()`
/// (components/startup_metric_utils/browser/startup_metric_utils.cc).
@MainActor
final class FirstFrameGate {
    private var waiters: [@MainActor () -> Void] = []
    private(set) var isOpen = false
    /// Whether the launch sample was taken, or can no longer be: a frame was
    /// committed, or the backstop opened the gate first.
    private(set) var launchSampleDone = false
    private let backstop: DemandTimer
    private let launchMetric: LaunchFirstFrameMetric

    /// - Parameters:
    ///   - backstop: The deadline that opens the gate when no frame comes;
    ///     tests inject a manual clock.
    ///   - launchMetric: Measures and records the first frame's launch
    ///     sample; tests inject fixed values and a recording spy.
    init(backstop: DemandTimer = DemandTimer(owner: "FirstFrameGate.backstop"),
         launchMetric: LaunchFirstFrameMetric) {
        self.backstop = backstop
        self.launchMetric = launchMetric
    }

    /// Runs `work` once the gate is open: at once when it already is, else in
    /// the order the work was added.
    func whenOpen(_ work: @escaping @MainActor () -> Void) {
        if isOpen { work() } else { waiters.append(work) }
    }

    /// The first window's first frame was committed: records the launch
    /// sample (first call of a launch the backstop did not interrupt), then
    /// opens the gate.
    func open() {
        if !launchSampleDone {
            launchSampleDone = true
            launchMetric.recordFirstFrame()
        }
        openGate()
    }

    /// Opens the gate after `delay` unless a frame opened it first; that
    /// interrupts the launch, so no later frame records a launch sample.
    func armBackstop(after delay: Duration) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in
            self?.launchSampleDone = true
            self?.openGate()
        }
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
