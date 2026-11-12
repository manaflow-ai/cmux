#if os(iOS)
import CmuxMobileDesign
import Testing
import UIKit

/// Jump to Bottom while a flick's momentum still moves the page (Leo, 2026-11-12: "if you already
/// have momentum scrolling up, like it doesn't fully jump to the bottom"): the momentum is stopped
/// before the page is moved, so the move is the only thing moving it.
@MainActor
@Suite struct ScrollMomentumTests {
    /// A scroll view whose finger and deceleration state the test sets, and which records how
    /// its offset was set.
    final class MovingScrollView: UIScrollView {
        var fakeDecelerating = false
        var fakeTracking = false
        private(set) var stops: [CGPoint] = []
        override var isDecelerating: Bool { fakeDecelerating }
        override var isTracking: Bool { fakeTracking }
        override var isDragging: Bool { fakeTracking }
        override func setContentOffset(_ offset: CGPoint, animated: Bool) {
            if !animated { stops.append(offset) }
            super.setContentOffset(offset, animated: animated)
        }
    }

    @Test func aDecelerationIsStoppedWhereThePageIs() {
        let view = MovingScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.contentSize = CGSize(width: 100, height: 1_000)
        view.contentOffset = CGPoint(x: 0, y: 400)
        view.fakeDecelerating = true
        #expect(view.haltScrollMomentum())
        #expect(view.stops == [CGPoint(x: 0, y: 400)])
    }

    @Test func aDragIsCancelledAndItsRecognizerStaysOn() {
        let view = MovingScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.fakeTracking = true
        #expect(view.haltScrollMomentum())
        #expect(view.panGestureRecognizer.isEnabled)
        #expect(view.stops.isEmpty)
    }

    @Test func aPageAtRestIsLeftAlone() {
        let view = MovingScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!view.haltScrollMomentum())
        #expect(view.stops.isEmpty)
    }
}
#endif
