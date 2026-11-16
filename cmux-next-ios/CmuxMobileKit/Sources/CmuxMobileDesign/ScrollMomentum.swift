#if os(iOS)
import UIKit

/// Stops what is moving a scroll view before code moves it: a finger's drag and the momentum a
/// flick left behind. A programmatic scroll (Jump to Bottom, Scroll to Top, Find) that only sets
/// or animates `contentOffset` leaves UIKit's deceleration running, so the page kept gliding the
/// way it was flung and never reached the target (Leo, 2026-11-12: "the jump to bottom button on
/// iOS, when you click it, like if you already have momentum scrolling up, like it doesn't fully
/// jump to the bottom"). The terminal's jump already did this; every scroll by code goes through here.
public extension UIScrollView {
    /// Ends a drag and any deceleration where the page is now. Returns whether anything was moving.
    @MainActor @discardableResult
    func haltScrollMomentum() -> Bool {
        var moving = false
        if isTracking || isDragging {
            // Toggling the pan recognizer cancels the gesture: the finger stops moving the page.
            panGestureRecognizer.isEnabled = false
            panGestureRecognizer.isEnabled = true
            moving = true
        }
        if isDecelerating {
            // A non-animated set to the current offset is UIKit's way to stop a deceleration.
            setContentOffset(contentOffset, animated: false)
            moving = true
        }
        return moving
    }
}
#endif
