import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Reference values: the iOS 26.5 / 27.0 simulator Messages under identical
/// XCUITest drags (bubble offset per finger travel past the peek point,
/// 58 pt stop for an iPhone 17 Pro), and ChatKit's peek rules.
@Suite struct TimestampDrawerPhysicsTests {
    private func drag(_ physics: inout TimestampDrawerPhysics, to point: CGPoint, steps: Int = 40) {
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            physics.update(translation: CGPoint(x: point.x * f, y: point.y * f))
        }
    }

    @Test func staysClosedInsideThePeekDistance() {
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -19.5, y: 0))
        #expect(p.offset == 0)
        #expect(!p.isPeeking)
    }

    @Test func followsTheMeasuredRubberBandPastThePeekPoint() {
        // Messages (iOS 26.5): 14 pt at 33 pt past the peek point, 30.7 pt at 73 pt.
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -50, y: 0))
        #expect(abs(p.offset - 12.8) < 0.5)
        drag(&p, to: CGPoint(x: -90, y: 0))
        #expect(abs(p.offset - 29.3) < 0.5)
    }

    @Test func iOS27NeedsTwentyMorePoints() {
        // Messages 27: 5.7 pt at 60 pt of travel where 26 shows it at 40 pt.
        var p = TimestampDrawerPhysics(maxOffset: 58, peekDistance: TimestampDrawerPhysics.iOS27PeekDistance)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -39, y: 0))
        #expect(p.offset == 0)
        drag(&p, to: CGPoint(x: -53, y: 0))
        #expect(abs(p.offset - 5.7) < 0.5)
    }

    @Test func stopsDeadAtTheDrawerWidth() {
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -400, y: 0))
        #expect(p.offset == 58)
        #expect(p.fraction == 1)
    }

    @Test func aSteepDragOnlyResamples() {
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        // 10 degrees: every 20 pt of travel resamples instead of peeking.
        drag(&p, to: CGPoint(x: -150, y: 26.4), steps: 150)
        #expect(!p.isPeeking)
        #expect(p.offset == 0)
    }

    @Test func aShallowDragPeeks() {
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -150, y: 7.9), steps: 150)
        #expect(p.isPeeking)
        #expect(p.offset > 40)
    }

    @Test func releaseFromRestFallsBackToZero() throws {
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -400, y: 0))
        let ended = p.end(velocity: .zero)
        let release = try #require(ended)
        #expect(release.offset(at: 0) == 58)
        // Messages: about 0.47 of the way back after 0.1 s, 0.15 after 0.25 s.
        #expect(abs(release.offset(at: 0.1) / 58 - 0.47) < 0.06)
        #expect(abs(release.offset(at: 0.25) / 58 - 0.15) < 0.05)
        var settled = false
        var t = 0.0
        while !settled, t < 2 { t += 1.0 / 60; settled = p.settle(release, elapsed: t) }
        #expect(settled)
        #expect(p.offset == 0)
        #expect(t < 1.2)
    }

    @Test func aFlingWaitsAtTheStopBeforeFallingBack() throws {
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -300, y: 0))
        let ended = p.end(velocity: CGPoint(x: -1500, y: 0))
        let release = try #require(ended)
        // Messages held about 0.16 s at the stop for a 1500 pt/s fling.
        #expect(release.offset(at: 0.1) == 58)
        #expect(release.offset(at: 0.25) < 58)
    }

    @Test func aDragCatchesASettlingDrawerWhereItIs() throws {
        var p = TimestampDrawerPhysics(maxOffset: 58)
        p.begin(translation: .zero)
        drag(&p, to: CGPoint(x: -400, y: 0))
        let ended = p.end(velocity: .zero)
        let release = try #require(ended)
        _ = p.settle(release, elapsed: 0.1)
        let caught = p.offset
        p.begin(translation: .zero)
        p.update(translation: .zero)
        #expect(p.isPeeking)
        #expect(abs(p.offset - caught) < 0.01)
    }

    @Test func labelSlidesFromJustPastTheEdgeToSeventeenInside() {
        // "11:09 AM" in the drawer font: 50.07 pt frame, ink 337.33...385 at a full reveal.
        #expect(TimestampDrawerLabelGeometry.minX(width: 402, labelWidth: 50.07, fraction: 0) == 402)
        #expect(abs(TimestampDrawerLabelGeometry.minX(width: 402, labelWidth: 50.07, fraction: 1) + 1.6 - 337.13) < 0.01)
        #expect(TimestampDrawerPhysics.drawerWidth(widestReferenceTime: 50.07, margin: 7) == 58)
        #expect(TimestampDrawerLabelGeometry.alpha(fraction: 0.5, fadesIn: true) == 0.25)
        #expect(TimestampDrawerLabelGeometry.alpha(fraction: 0.5, fadesIn: false) == 1)
        #expect(TimestampDrawerLabelGeometry.alpha(fraction: 0, fadesIn: false) == 0)
    }
}
