import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// The one armed read of the Floating Pane knobs (`FloatingPaneTunables`) for a screen's cards. A layout pass reads
/// the look through it; while no knob changed since the last read, the read registers nothing more.
final class FloatingPaneLookWatch {
    private let tracking = SingleArmedTracking()

    /// The look now. `onChange` runs once after a knob changed, in the main queue's next turn: the knob's write is
    /// done then, so the pass that `onChange` asks for reads the new value.
    func read(onChange: @escaping @MainActor @Sendable () -> Void) -> FloatingPaneLook {
        tracking.track(shape: []) {
            FloatingPaneLook.current
        } onChange: {
            MainDelivery().later(onChange)
        }
    }
}
