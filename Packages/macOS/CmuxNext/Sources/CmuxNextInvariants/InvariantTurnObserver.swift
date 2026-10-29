#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import CoreFoundation

/// The one check point of the invariant framework (plans/cmux-next/invariants-DESIGN.md section 3.1): a repeating
/// main run-loop observer of `beforeWaiting` and `exit` in the common modes (so live resize and menu tracking too)
/// that calls ``InvariantRegistry/runTurn()`` once each committed turn ends. Main-owned state changes only in a main
/// turn, and a display-link frame, an action, an event and a daemon apply each run as one, so this covers every
/// frame in which the model can change. It adds no display link, no frame client and no wakeup: it runs only in
/// turns that other work started, and an idle turn costs one test.
///
/// It runs inside the before-waiting render phase, so the composition root passes `around` to put each pass in a
/// span of its own (the app's turn meter: `MainTurnMeter.debugCheck`): the pass is then neither render time, which the
/// frame budget plans from, nor unattributed time, and an armed run can subtract it.
@MainActor
public final class InvariantTurnObserver {
    /// After the Core Animation commit (2_000_000), `CommitBoundary` (2_000_001), the typing probe's echo
    /// (2_000_100) and `FramePresentEstimate` (2_000_200): the pass changes no time those observers measure.
    static let order: CFIndex = 2_000_300

    private var observer: MainRunLoopObserver?

    /// Starts checking `registry` at the end of every turn, until ``invalidate()`` or release.
    /// - Parameter around: Runs each pass (the app: inside its turn meter's debug-check span); nil runs it bare.
    public init(registry: InvariantRegistry, around: (@MainActor (() -> Void) -> Void)? = nil) {
        observer = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: Self.order) { [weak registry] _ in
            guard let registry else { return }
            if let around { around { registry.runTurn() } } else { registry.runTurn() }
        }
    }

    /// Stops checking.
    public func invalidate() {
        observer?.invalidate()
        observer = nil
    }
}
#endif
