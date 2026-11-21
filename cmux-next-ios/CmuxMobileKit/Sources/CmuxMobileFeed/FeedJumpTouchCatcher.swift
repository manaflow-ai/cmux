#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Takes a touch on the Feed while its jump to the top (the "N new" pill) moves the list.
///
/// The rows move under the finger during the jump, so a tap then is never meant for the row it
/// lands on. While `isArmed` answers true, a touch begins this recognizer at once: by UIKit's
/// default exclusivity that fails the rows' tap recognizers and cancels the touch in their buttons,
/// and its action stops the jump. The list's own pan still runs with it, so the person can drag
/// on from there. Unarmed, it fails at the first touch and the list behaves as without it.
final class FeedJumpTouchCatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var isArmed: @MainActor () -> Bool = { false }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
        cancelsTouchesInView = true
        delaysTouchesBegan = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else { return }
        state = isArmed() ? .began : .failed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if state == .began || state == .changed { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if state == .began || state == .changed { state = .cancelled }
    }

    /// The list's pan runs alongside: a touch that stops the jump can go on as a drag.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (view as? UIScrollView)?.panGestureRecognizer === other
    }
}
#endif
