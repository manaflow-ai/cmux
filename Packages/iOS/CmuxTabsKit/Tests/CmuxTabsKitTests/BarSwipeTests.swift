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

    /// The travel is fixed when the swipe starts: the card's rect moving
    /// under the page (the grid's first scroll-origin report) does not move
    /// the page under the finger.
    @Test func travelIsFrozenAtTheStart() {
        let full = CGRect(x: 0, y: 0, width: 400, height: 860)
        let swipe = BarSwipe.Tracking(path: ZoomRectPath(full: full, card: CGRect(x: 20, y: 120, width: 170, height: 240)))
        #expect(swipe.travel == 500)
        let before = swipe.progress(up: 200)
        // The grid reports its origin: the card moves 300 pt down.
        let moved = BarSwipe.Tracking(path: ZoomRectPath(full: full, card: CGRect(x: 20, y: 420, width: 170, height: 240)))
        #expect(moved.travel != swipe.travel)
        #expect(swipe.progress(up: 200) == before)
        #expect(before == BarSwipe.progress(up: 200, travel: 500))
        #expect(swipe.velocity(1000) == BarSwipe.velocity(1000, travel: 500))
        #expect(BarSwipe.Tracking(path: nil).travel == BarSwipe.defaultTravel)
    }

    /// Only a zoom left interactive with no pinch holding it is released on
    /// a cancel; a settled or running zoom, or a pinch's, is left alone.
    @Test func cancelReleasesOnlyTheSwipesInteractiveZoom() {
        #expect(BarSwipe.releasesOnCancel(phase: .interactive, pinchActive: false))
        #expect(!BarSwipe.releasesOnCancel(phase: .interactive, pinchActive: true))
        #expect(!BarSwipe.releasesOnCancel(phase: .page, pinchActive: false))
        #expect(!BarSwipe.releasesOnCancel(phase: .overview, pinchActive: false))
        #expect(!BarSwipe.releasesOnCancel(phase: .animating, pinchActive: false))
    }

    /// A swipe cancelled part-way settles at the nearer end and never stays
    /// interactive: short of half way back to the page (the bar takes
    /// touches again), past it on to the grid; also from the rubber band.
    @Test func cancelledSwipeSettlesAtTheNearerEnd() {
        let swipe = BarSwipe.Tracking(path: nil)
        let cases: [(up: CGFloat, toOverview: Bool)] = [(0, false), (60, false), (200, false), (260, true), (450, true), (900, true), (-40, false)]
        for c in cases {
            var s = TabZoomState()
            s.beginInteraction()
            s.updateInteraction(progress: swipe.progress(up: c.up), velocity: swipe.velocity(1500))
            #expect(BarSwipe.releasesOnCancel(phase: s.phase, pinchActive: false), "up \(c.up)")
            let toOverview = BarSwipe.releaseToOverviewOnCancel(progress: s.progress)
            #expect(toOverview == c.toOverview, "up \(c.up)")
            s.updateInteraction(progress: s.progress, velocity: 0)
            s.release(toOverview: toOverview)
            #expect(s.phase != .interactive, "up \(c.up)")
            var t = 0.0
            while t < 1.5 { s.step(1.0 / 60); t += 1.0 / 60 }
            #expect(s.phase == (toOverview ? .overview : .page), "up \(c.up)")
            #expect(toOverview ? s.gridInteractive : s.pageInteractive, "up \(c.up)")
            #expect(!BarSwipe.releasesOnCancel(phase: s.phase, pinchActive: false), "up \(c.up)")
        }
    }
}
