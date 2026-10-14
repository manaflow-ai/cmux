@testable import CmuxTabsKit
import CoreGraphics
import Testing

struct BarSwipeTests {
    @Test func axisFromTheFirstMovement() {
        #expect(BarSwipe.axis(CGSize(width: 20, height: -5)) == .horizontal)
        #expect(BarSwipe.axis(CGSize(width: -4, height: -20)) == .up)
        #expect(BarSwipe.axis(CGSize(width: 2, height: 15)) == .down)
    }

    /// Safari: 270 pt up has the page about 0.6 of the way to its card.
    @Test func followsTheFinger() {
        #expect(abs(BarSwipe.progress(up: 270) - 0.6) < 0.01)
        #expect(BarSwipe.progress(up: 0) == 0)
    }
}
