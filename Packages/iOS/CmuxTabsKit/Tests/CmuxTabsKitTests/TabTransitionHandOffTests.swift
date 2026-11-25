@testable import CmuxTabsKit
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation
import Testing

/// The page <-> grid zoom transition hands off without a shift, in every
/// variant (Leo, 2026-11-25: "the entering and exiting of this animation
/// between the true window and the preview is not smooth and correct
/// enough. things shift, things lag, things dont feel like candy").
///
/// Hand-off: the zoom's last frame and the settled card (on the grid) or
/// the settled page are the same rect within 1 pt, with the same corner
/// radius and shadow. Interruptible: a tap mid-flight retargets from the
/// zoom's current position and velocity.
struct TabTransitionHandOffTests {
    private let full = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let layout = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 6)
    /// The grid scrolled 120 pt, its content reported 3 pt right (where
    /// grid content point (0, 0) is on screen).
    private let gridOrigin = CGPoint(x: 3, y: -120)
    private let screenRadius: CGFloat = 55
    private let index = 3

    private func presented(_ s: TabZoomState, _ v: TabTransitionVariant) -> ZoomPresentation {
        // As TabsView draws it: the zoom flies to the grid's card end on
        // screen (`OverviewLayout.zoomEndpoint`); settled on the grid the
        // page is the card in content coordinates, following the grid.
        let moving = s.phase == .animating || s.phase == .interactive
        let card = moving ? layout.holding(index).zoomEndpoint(index, contentOrigin: gridOrigin, fallbackOffset: 0)
            : layout.holding(index).card(index)
        return ZoomPresentation.make(s, full: full, card: card, gridOrigin: .zero, screenRadius: screenRadius,
                                     cardRadius: layout.cardRadius, variant: v)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }

    /// Steps at 120 Hz until the zoom settles; returns the last moving
    /// frame and the first settled one.
    private func settle(_ s: inout TabZoomState, _ v: TabTransitionVariant) -> (last: ZoomPresentation, settled: ZoomPresentation) {
        var last = presented(s, v)
        for _ in 0..<600 where s.phase == .animating {
            last = presented(s, v)
            s.step(1.0 / 120)
        }
        return (last, presented(s, v))
    }

    @Test(arguments: TabTransitionVariant.all)
    func cardFrameMatchesAtTheHandOffToTheGrid(_ v: TabTransitionVariant) {
        var s = TabZoomState(motion: v)
        s.go(toOverview: true)
        let (last, settled) = settle(&s, v)
        #expect(s.phase == .overview, "\(v.name)")
        let card = layout.card(index).offsetBy(dx: gridOrigin.x, dy: gridOrigin.y)
        #expect(settled.followsGrid)
        #expect(distance(settled.screenRect(gridOrigin: gridOrigin), card) < 0.001, "\(v.name)")
        #expect(distance(last.screenRect(gridOrigin: gridOrigin), settled.screenRect(gridOrigin: gridOrigin)) <= 1, "\(v.name)")
        #expect(abs(last.radius - settled.radius) <= 0.5, "\(v.name)")
        #expect(abs(last.shadow - settled.shadow) <= 0.02, "\(v.name)")
    }

    @Test(arguments: TabTransitionVariant.all)
    func pageFrameMatchesAtTheHandOffToThePage(_ v: TabTransitionVariant) {
        var s = TabZoomState(overview: true, motion: v)
        s.go(toOverview: false)
        let (last, settled) = settle(&s, v)
        #expect(s.phase == .page, "\(v.name)")
        #expect(settled.rect == full && !settled.followsGrid)
        #expect(distance(last.screenRect(gridOrigin: gridOrigin), full) <= 1, "\(v.name)")
        #expect(last.shadow <= 0.02 && settled.shadow == 0, "\(v.name)")
    }

    /// A reversal mid-flight, toward either end, in every variant: the
    /// frame of the tap is the frame before it (no jump) and the next frame
    /// carries the momentum it had (no restart from rest), then the zoom
    /// still hands off within 1 pt.
    @Test(arguments: TabTransitionVariant.all)
    func tapMidFlightRetargetsFromPositionAndVelocity(_ v: TabTransitionVariant) {
        for toOverview in [true, false] {
            var s = TabZoomState(overview: !toOverview, motion: v)
            s.go(toOverview: toOverview)
            for _ in 0..<14 { s.step(1.0 / 120) }
            let before = presented(s, v).rect
            let p = s.progress, vel = s.velocity
            #expect(vel != 0, "\(v.name) \(toOverview)")
            s.go(toOverview: !toOverview)
            #expect(s.progress == p && s.velocity == vel, "\(v.name) \(toOverview)")
            #expect(distance(presented(s, v).rect, before) == 0, "\(v.name) \(toOverview)")
            s.step(1.0 / 120)
            // Still moving the way it was for this frame.
            #expect(toOverview ? s.progress > p : s.progress < p, "\(v.name) \(toOverview)")
            let (last, settled) = settle(&s, v)
            #expect(distance(last.screenRect(gridOrigin: gridOrigin), settled.screenRect(gridOrigin: gridOrigin)) <= 1,
                    "\(v.name) \(toOverview)")
        }
    }

    /// A pinch grabbed mid-flight continues from the presented rect.
    @Test func dragMidFlightStartsWhereTheZoomIs() {
        var s = TabZoomState()
        s.go(toOverview: true)
        for _ in 0..<10 { s.step(1.0 / 120) }
        let p = s.progress
        s.beginInteraction()
        #expect(s.phase == .interactive && s.progress == p)
    }

    /// One tab plus the new tab's placeholder is a two-card grid: the zoom
    /// lands on the card the grid draws, not the lone centred card.
    @Test func cardEndUsesTheGridsCardCount() {
        let grid = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 2)
        #expect(grid.holding(0).card(0) == grid.card(0))
        #expect(grid.holding(4).count == 5)
        let lone = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 1)
        #expect(lone.card(0) != grid.card(0))
    }

    /// The grid's reported origin and the fallback before it reports give
    /// the card on screen where the settled card follows the grid to.
    @Test func cardEndIsTheSettledCardOnScreen() {
        #expect(layout.zoomEndpoint(index, contentOrigin: gridOrigin, fallbackOffset: 0)
            == layout.card(index).offsetBy(dx: gridOrigin.x, dy: gridOrigin.y))
        #expect(layout.zoomEndpoint(index, contentOrigin: nil, fallbackOffset: 120)
            == layout.card(index).offsetBy(dx: 0, dy: -120))
    }

    @Test(arguments: TabTransitionVariant.all)
    func radiusAndShadowMeetBothEnds(_ v: TabTransitionVariant) {
        #expect(v.radius(progress: 0, screen: 55, card: 14) == 55)
        #expect(abs(v.radius(progress: 1, screen: 55, card: 14) - 14) < 0.001)
        #expect(v.shadow(progress: 0) == 0 && v.shadow(progress: 1) == 1)
        var previous = 0.0
        for i in 0...20 {
            let q = v.shadow(progress: Double(i) / 20)
            #expect(q >= previous)
            previous = q
        }
        #expect(v.gridScale(shown: 1) == 1 && v.gridBlur(shown: 1) == 0)
    }

    /// Today's look stays the default.
    @Test func defaultIsTodaysLook() {
        let d = TabTransitionVariant.named(nil)
        #expect(d == .safari && TabZoomState().motion == .safari)
        #expect(d.toOverview == .toOverview && d.toPage == .toPage && d.release == .release)
        #expect(d.retargetToPage == .reversalToPage && d.retargetToOverview == .reversalToOverview)
        #expect(d.replaysSafariCurve && d.settleScale == 0.06 && d.settleBlur == 10)
        #expect(abs(d.gridScale(shown: 0) - 1.06) < 1e-9 && d.gridBlur(shown: 0) == 10)
        var s = TabZoomState()
        s.go(toOverview: true)
        #expect(s.curve == .zoomOut)
    }

    @Test func variantsAreChosenByName() {
        #expect(TabTransitionVariant.named("soft") == .soft)
        #expect(TabTransitionVariant.named(" Crisp ") == .crisp)
        #expect(TabTransitionVariant.named("still") == .still)
        #expect(TabTransitionVariant.named("nope") == .safari)
        #expect(Set(TabTransitionVariant.all.map(\.name)).count == 4)
        let defaults = UserDefaults(suiteName: "tabs-transition-\(UUID().uuidString)")!
        #expect(TabTransitionVariant.fromEnvironment(defaults: defaults, environment: ["CMUX_TABS_TRANSITION": "soft"]) == .soft)
        defaults.set("crisp", forKey: "tabs-transition")
        #expect(TabTransitionVariant.fromEnvironment(defaults: defaults, environment: ["CMUX_TABS_TRANSITION": "soft"]) == .crisp)
        // Springs-only variants do not replay Safari's curve.
        var s = TabZoomState(motion: .crisp)
        s.go(toOverview: true)
        #expect(s.curve == nil && s.spring == TabTransitionVariant.crisp.toOverview)
    }
}

extension TabTransitionVariant: CustomTestStringConvertible {
    public var testDescription: String { name }
}
