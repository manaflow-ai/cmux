#if canImport(UIKit)
import CmuxMobileTerminalKit
import UIKit

final class TerminalScrollMechanicsView: UIScrollView {
    private let backSwipeEdgeReservation = TerminalBackSwipeEdgeReservation()

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           let window {
            let touchXInWindow = Double(gestureRecognizer.location(in: window).x)
            if backSwipeEdgeReservation.shouldReserveSystemBackSwipeEdge(touchXInWindow: touchXInWindow) {
                return false
            }
        }

        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
#endif
