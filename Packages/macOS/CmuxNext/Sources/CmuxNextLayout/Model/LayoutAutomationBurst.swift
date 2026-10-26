public import CmuxNextWakeups

/// Counts one window's automation-caused structural layout changes per frame
/// (plans/cmux-next/chrome-parity/p06-scheduler.md section D, task 038). The first one in a
/// frame moves as the person's would; the second and later ones land at once, so a script that
/// splits five panes in one frame starts no spring and the window lays out its final state once.
///
/// Chrome commits main-thread changes once per begin-frame (`cc/trees/layer_tree_host.cc`,
/// `BeginMainFrame`) and coalesces continuous input to it
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`). cmux goes
/// past that for scripts (CLAUDE.md "Go past Chrome where cmux is scripted"): a spring that a
/// burst of scripted changes restarts every frame never lands and costs a layout per frame, so
/// the burst's later changes do not animate. A person's or the app's own change always moves.
///
/// ```swift
/// // One per window (`WindowState.layoutBurst`); every workspace layout of the window shares it.
/// let burst = LayoutAutomationBurst(frame: { budget.stats.frames })
/// layoutModel.automationBurst = burst
/// layoutModel.apply(screens: screens, cause: causes.currentCause)
/// ```
@MainActor
public final class LayoutAutomationBurst {
    /// The frame now: any value that changes from one frame to the next (the main frame budget's
    /// frame count in the app, a test's counter).
    private let frame: @MainActor () -> Int
    /// The frame counted and its automation structural changes so far.
    private var counted: (frame: Int, changes: Int)?
    /// Structural changes this burst landed at once, cumulative (diagnostics and tests).
    public private(set) var snapped = 0

    /// - Parameter frame: The current frame's sequence number.
    public init(frame: @escaping @MainActor () -> Int) {
        self.frame = frame
    }

    /// Counts a structural change caused by `cause` and says whether it lands at once: only the
    /// second or later automation-caused one in the current frame does.
    ///
    /// - Parameter cause: Who caused the change.
    /// - Returns: True when the change applies with no motion.
    public func snaps(_ cause: ObservationCause) -> Bool {
        guard cause == .automation else { return false }
        let now = frame()
        var count = counted.flatMap { $0.frame == now ? $0.changes : nil } ?? 0
        count += 1
        counted = (now, count)
        guard count > 1 else { return false }
        snapped += 1
        return true
    }
}
