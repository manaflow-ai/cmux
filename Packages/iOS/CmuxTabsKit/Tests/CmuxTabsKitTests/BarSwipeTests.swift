@testable import CmuxTabsKit
import CoreGraphics
import Testing

struct BarSwipeTests {
    @Test func axisFromTheFirstMovement() {
        #expect(BarSwipe.axis(CGSize(width: 20, height: -5)) == .horizontal)
        #expect(BarSwipe.axis(CGSize(width: -4, height: -20)) == .up)
        #expect(BarSwipe.axis(CGSize(width: 2, height: 15)) == .down)
    }

    private let travel: CGFloat = 400

    /// Zero travel is the page; no movement, no zoom.
    @Test func zeroTravelIsThePage() {
        #expect(BarSwipe.progress(up: 0, travel: travel) == 0)
        #expect(BarSwipe.velocity(0, travel: travel) == 0)
        #expect(!BarSwipe.releaseToOverview(progress: 0, velocity: 0))
    }

    /// The page stays under the thumb: progress is linear in the finger's
    /// travel (equal steps of travel give equal steps of progress, so it never
    /// accelerates ahead of a slow finger).
    @Test func progressIsLinearInTravel() {
        for up: CGFloat in [10, 50, 100, 200, 300] {
            #expect(abs(BarSwipe.progress(up: up, travel: travel) - Double(up / travel)) < 1e-12)
        }
        let a = BarSwipe.progress(up: 40, travel: travel), b = BarSwipe.progress(up: 80, travel: travel)
        #expect(abs(b - 2 * a) < 1e-12)
    }

    /// Full travel reaches the card exactly; past it the page rubber-bands and
    /// never runs off.
    @Test func fullTravelReachesTheCard() {
        #expect(BarSwipe.progress(up: travel, travel: travel) == 1)
        let past = BarSwipe.progress(up: travel * 3, travel: travel)
        #expect(past > 1 && past < 1 + BarSwipe.bandBeyondCard)
        let below = BarSwipe.progress(up: -200, travel: travel)
        #expect(below < 0 && below > -BarSwipe.bandBeyondPage)
        #expect(BarSwipe.releaseToOverview(progress: 1, velocity: 0))
    }

    /// The release spring starts at the finger's speed: 800 pt/s over 400 pt
    /// of travel is 2 progress/s.
    @Test func releaseVelocityIsTheFingers() {
        #expect(BarSwipe.velocity(800, travel: travel) == 2)
        #expect(BarSwipe.velocity(-200, travel: travel) == -0.5)
    }

    /// A fast flick over a short travel still opens the grid.
    @Test func fastFlickShortTravelOpensTheGrid() {
        let p = BarSwipe.progress(up: 40, travel: travel)
        let v = BarSwipe.velocity(1200, travel: travel)
        #expect(BarSwipe.releaseToOverview(progress: p, velocity: v))
    }

    /// A slow release past half way goes on to the grid; short of it, back.
    @Test func slowReleaseDecidesByPosition() {
        let slow = BarSwipe.velocity(20, travel: travel)
        #expect(BarSwipe.releaseToOverview(progress: BarSwipe.progress(up: 240, travel: travel), velocity: slow))
        #expect(!BarSwipe.releaseToOverview(progress: BarSwipe.progress(up: 120, travel: travel), velocity: slow))
        #expect(BarSwipe.releaseToOverview(progress: BarSwipe.progress(up: 240, travel: travel), velocity: 0))
    }

    /// A finger that turns back down cancels, even from far up.
    @Test func reverseDragCancels() {
        let p = BarSwipe.progress(up: 340, travel: travel)
        #expect(!BarSwipe.releaseToOverview(progress: p, velocity: BarSwipe.velocity(-100, travel: travel)))
        #expect(!BarSwipe.releaseToOverview(progress: p, velocity: BarSwipe.velocity(-1500, travel: travel)))
    }

    /// Travel is the page's bottom edge to its card's, never less than the
    /// minimum, and the default without a card.
    @Test func travelFromThePath() {
        let full = CGRect(x: 0, y: 0, width: 400, height: 860)
        #expect(BarSwipe.travel(path: nil) == BarSwipe.defaultTravel)
        #expect(BarSwipe.travel(path: ZoomRectPath(full: full, card: CGRect(x: 20, y: 120, width: 170, height: 240))) == 500)
        #expect(BarSwipe.travel(path: ZoomRectPath(full: full, card: CGRect(x: 20, y: 600, width: 170, height: 240))) == BarSwipe.minimumTravel)
        #expect(BarSwipe.travel(path: ZoomRectPath(full: full, card: .zero)) == BarSwipe.defaultTravel)
    }
}
