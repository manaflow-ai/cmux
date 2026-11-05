public import CmuxNextWakeups
#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
#endif

/// Launch work that waits until the first window's first frame is committed,
/// so it never delays that frame (perf-launch-memory): the updater, SSH and
/// server-reach starts, and the warm-ups for later tabs.
///
/// The app (`AppDelegate`) opens it from the first window's `CATransaction` completion.
/// A launch that shows no window (an agent launch, a daemon that never
/// answers) still opens it after `backstop`, so the work always runs.
@MainActor
public final class FirstFrameGate {
    private var waiters: [@MainActor () -> Void] = []
    public private(set) var isOpen = false
    private let backstop: DemandTimer

    /// - Parameter backstop: The deadline that opens the gate when no frame
    ///   comes; tests inject a manual clock.
    public init(backstop: DemandTimer = DemandTimer(owner: "FirstFrameGate.backstop")) {
        self.backstop = backstop
        #if DEBUG || CMUX_BENCH_HOOKS
        if Self.inApp { CoreAnimationFenceLaunchProbe(phase: "launch").run(layer: nil) }
        #endif
    }

    /// Runs `work` once the gate is open: at once when it already is, else in
    /// the order the work was added.
    public func whenOpen(_ work: @escaping @MainActor () -> Void) {
        if isOpen { work() } else { waiters.append(work) }
    }

    /// Opens the gate (first call only) and runs the waiting work.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        backstop.cancel()
        let waiting = waiters
        waiters.removeAll()
        for work in waiting { work() }
        #if DEBUG || CMUX_BENCH_HOOKS
        // SPIKE (scratch/frame-owner-s4-fence-spike-nomerge): a real fence on the first window's context, logged as a
        // FENCE-PROBE line for the Tart OS matrix.
        if Self.inApp {
            let window = NSApplication.shared.windows.first { $0.isVisible && $0.contentView?.layer != nil }
            CoreAnimationFenceLaunchProbe(phase: "first_window").run(layer: window?.contentView?.layer)
        }
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The FENCE-PROBE spike runs only in the app bundle, never in a test process that makes a gate.
    private static var inApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    #endif

    /// Opens the gate after `delay` unless a frame opened it first.
    public func armBackstop(after delay: Duration) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in self?.open() }
    }

    /// Returns once the gate is open (at once when it already is).
    public func opened() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in whenOpen { done.resume() } }
    }
}
