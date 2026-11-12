@testable import CmuxTabsKit
import CoreGraphics
import Testing

struct BarSwipeTests {
    private let full = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let card = CGRect(x: 20, y: 300, width: 170, height: 300)
    private var path: ZoomRectPath { ZoomRectPath(full: full, card: card) }
    private var swipe: BarSwipe { BarSwipe(startRect: full, startFinger: CGPoint(x: 201, y: 830)) }

    @Test func axisFromTheFirstMovement() {
        #expect(BarSwipe.axis(CGSize(width: 20, height: -5)) == .horizontal)
        #expect(BarSwipe.axis(CGSize(width: -4, height: -20)) == .up)
        #expect(BarSwipe.axis(CGSize(width: 2, height: 15)) == .down)
    }

    /// Progress is linear in thumb travel (no time curve, no gain) up to the
    /// card, and rubber-bands past it, never more than the band.
    @Test func progressIsLinearInTravel() {
        for up: CGFloat in [0, 17, 50, 100, 200, 375] {
            #expect(abs(BarSwipe.progress(up: up) - Double(up / BarSwipe.travel)) < 1e-12)
        }
        #expect(BarSwipe.progress(up: -40) == 0)
        let past = BarSwipe.progress(up: BarSwipe.travel * 2)
        #expect(past > 1 && past < 1 + BarSwipe.bandBeyondCard)
        #expect(BarSwipe.progress(up: BarSwipe.travel * 3) > past)
    }

    /// The point of the page under the thumb stays under it through the
    /// whole drag, sideways too (the bar Leo set: within 2 pt; this is exact).
    @Test func heldPointStaysUnderTheThumb() {
        let s = swipe
        for (dx, up) in [(0.0, 0.0), (0, 12), (5, 60), (-30, 140), (12, 260), (0, 375), (40, 420)] as [(CGFloat, CGFloat)] {
            let finger = CGPoint(x: s.startFinger.x + dx, y: s.startFinger.y - up)
            let st = s.state(finger: finger, path: path)
            let held = s.heldPoint(progress: st.progress, offset: st.offset, path: path)
            #expect(abs(held.x - finger.x) < 0.01 && abs(held.y - finger.y) < 0.01)
        }
    }

    /// The first tracked frame does not move the page (no jump by the slop).
    @Test func noJumpWhereTheDragEngages() {
        let s = swipe
        let st = s.state(finger: s.startFinger, path: path)
        #expect(st.progress == 0 && st.offset == .zero)
        #expect(path.rect(progress: st.progress, offset: st.offset) == full)
    }

    /// Below the start the page moves down only a little (rubber band) and
    /// stays page sized.
    @Test func rubberBandsBelowTheStart() {
        let s = swipe
        let st = s.state(finger: CGPoint(x: s.startFinger.x, y: s.startFinger.y + 300), path: path)
        #expect(st.progress == 0)
        #expect(st.offset.dy > 0 && st.offset.dy < BarSwipe.bandBelowStart)
    }

    /// The release starts at the thumb's own speed: carried by the spring,
    /// the held point's first instant moves with the thumb's velocity.
    @Test func releaseVelocityMatchesTheThumb() {
        let s = swipe
        let finger = CGPoint(x: 210, y: 600)
        let v = CGVector(dx: 50, dy: -900)
        let rv = s.releaseVelocity(finger: finger, velocity: v, path: path)
        #expect(abs(rv.p - 900 / Double(BarSwipe.travel)) < 1e-6)
        let st = s.state(finger: finger, path: path)
        let h = 1.0 / 1000
        let a = s.heldPoint(progress: st.progress, offset: st.offset, path: path)
        let b = s.heldPoint(progress: st.progress + rv.p * h,
                            offset: CGVector(dx: st.offset.dx + rv.o.dx * h, dy: st.offset.dy + rv.o.dy * h), path: path)
        #expect(abs((b.x - a.x) / h - v.dx) < 2 && abs((b.y - a.y) / h - v.dy) < 2)
    }

    /// A fling goes the way it moves; a slow release opens the grid past a quarter.
    @Test func releaseDecision() {
        #expect(BarSwipe.releaseToOverview(progress: 0.05, velocityUp: 600))
        #expect(!BarSwipe.releaseToOverview(progress: 0.8, velocityUp: -600))
        #expect(BarSwipe.releaseToOverview(progress: 0.3, velocityUp: 0))
        #expect(!BarSwipe.releaseToOverview(progress: 0.15, velocityUp: 0))
    }

    /// Released toward the grid, the bar spring starts with the thumb's
    /// velocity (no stop at lift) and lands on the card.
    @Test func releaseSpringKeepsTheThumbsVelocity() {
        var z = TabZoomState()
        z.beginInteraction()
        z.updateInteraction(progress: 0.4, offset: CGVector(dx: 10, dy: -30), velocity: 2.4, offsetVelocity: CGVector(dx: 0, dy: -200))
        z.release(toOverview: true, spring: .barSwipeToOverview)
        #expect(z.velocity == 2.4 && z.offsetVelocity.dy == -200)
        z.step(1.0 / 120)
        #expect(z.progress > 0.4 + 2.4 / 120 * 0.8)
        for _ in 0..<240 { z.step(1.0 / 120) }
        #expect(z.phase == .overview && z.progress == 1 && z.offset == .zero)
    }
}
