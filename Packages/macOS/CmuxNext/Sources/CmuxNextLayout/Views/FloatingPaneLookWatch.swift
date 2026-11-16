import CmuxNextDesign
import Observation

/// A tracked read of the Floating Pane knobs for one screen's cards: a knob that changes shows on each open
/// floating pane in the next turn of the main actor. No timer runs, and nothing is armed while no one reads.
final class FloatingPaneLookWatch {
    private var isArmed = false

    /// The look now. A read that is not armed arms one tracked read of the knobs: `onChange` runs once, in the next
    /// turn of the main actor after a knob changes, and the next read arms again.
    func read(onChange: @escaping @MainActor () -> Void) -> FloatingPaneLook {
        guard !isArmed else { return FloatingPaneLook.current }
        isArmed = true
        return withObservationTracking { FloatingPaneLook.current } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isArmed = false
                onChange()
            }
        }
    }
}
