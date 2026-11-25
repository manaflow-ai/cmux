@testable import CmuxTabsKit
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing

/// The page -> grid zoom is one matched-geometry motion: it starts on the
/// page, ends on its cell, and the settled frame is the last animated one
/// (Leo, 2026-11-24: "things shift, things lag").
struct ZoomGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 440, height: 956)
    private var grid: OverviewLayout {
        OverviewLayout(size: screen.size, safeTop: 62, safeBottom: 34, count: 7)
    }

    /// Points the rect's edges move per unit of progress (the larger span).
    private func pointsPerUnit(_ path: ZoomRectPath) -> CGFloat {
        max(abs(path.full.height - path.card.height), abs(path.full.width - path.card.width))
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }

    /// Every frame's rect from `s` until it settles, the cell end following
    /// the grid's scale as it does on screen.
    private func frames(_ s: inout TabZoomState, cell: CGRect) -> (rects: [CGRect], settled: Bool) {
        var rects: [CGRect] = []
        for _ in 0..<240 {
            let done = s.step(1.0 / 60)
            let path = ZoomRectPath(full: screen, card: grid.zoomScaled(cell, shown: min(1, max(0, s.progress))))
            rects.append(path.rect(progress: s.progress, offset: s.offset))
            if done { return (rects, true) }
        }
        return (rects, false)
    }

    @Test func startsOnThePageAndEndsOnItsCell() {
        let cell = grid.zoomEndpoint(3, contentOrigin: CGPoint(x: 0, y: -120), fallbackOffset: 0)
        #expect(cell == grid.screenFrame(3, offset: 120))
        let start = ZoomRectPath(full: screen, card: grid.zoomScaled(cell, shown: 0))
        #expect(start.rect(progress: 0) == screen)
        let end = ZoomRectPath(full: screen, card: grid.zoomScaled(cell, shown: 1))
        #expect(end.rect(progress: 1) == cell)
    }

    /// The cell end is where the grid draws the cell under its zoom scale,
    /// computed in the same frame: 1.06 about the screen's center while the
    /// grid is hidden, exactly the cell once shown.
    @Test func cellEndFollowsTheGridScale() {
        let cell = grid.screenFrame(4, offset: 0)
        #expect(grid.zoomScaled(cell, shown: 1) == cell)
        #expect(grid.zoomScaled(cell, shown: 2) == cell)
        let hidden = grid.zoomScaled(cell, shown: 0)
        #expect(abs(hidden.width - cell.width * 1.06) < 0.001)
        let c = CGPoint(x: screen.midX, y: screen.midY)
        #expect(abs((hidden.minX - c.x) - (cell.minX - c.x) * 1.06) < 0.001)
        #expect(abs((hidden.minY - c.y) - (cell.minY - c.y) * 1.06) < 0.001)
        // Continuous in `shown`: no step anywhere on the way.
        var last = hidden
        for i in 1...100 {
            let r = grid.zoomScaled(cell, shown: Double(i) / 100)
            #expect(distance(r, last) < 1)
            last = r
        }
        #expect(last == cell)
    }

    /// Tabs button: the settled grid draws the card exactly where the last
    /// animated frame left it, and the last frames close in without a nudge.
    @Test func enterSettlesWhereTheLastFrameWas() {
        let cell = grid.screenFrame(2, offset: 0)
        var s = TabZoomState()
        s.go(toOverview: true)
        let (rects, settled) = frames(&s, cell: cell)
        #expect(settled && s.phase == .overview)
        #expect(rects.first.map { distance($0, screen) < 40 } == true)
        #expect(rects.last.map { distance($0, cell) < 0.001 } == true)
        let tail = rects.suffix(12)
        for (a, b) in zip(tail, tail.dropFirst()) { #expect(distance(a, b) < 0.5) }
    }

    /// Done: the exit runs the same path back, ending on the page exactly.
    @Test func exitIsTheReversedPathAndEndsOnThePage() {
        let cell = grid.screenFrame(2, offset: 0)
        var s = TabZoomState(overview: true)
        s.go(toOverview: false)
        let (rects, settled) = frames(&s, cell: cell)
        #expect(settled && s.phase == .page)
        #expect(rects.last == screen)
        let tail = rects.suffix(8)
        for (a, b) in zip(tail, tail.dropFirst()) { #expect(distance(a, b) < 1) }
    }

    /// A spring settle (reversal, pinch release) snaps to the target from
    /// under a quarter point away, so the settle frame does not jump.
    @Test func springSettleDoesNotJump() throws {
        let cell = grid.screenFrame(2, offset: 0)
        let ppu = pointsPerUnit(ZoomRectPath(full: screen, card: cell))
        for toOverview in [true, false] {
            var s = TabZoomState(overview: !toOverview)
            s.go(toOverview: toOverview)
            for _ in 0..<6 { s.step(1.0 / 60) }
            s.go(toOverview: !toOverview)  // reversal: a spring, not a curve
            var settledFrom: Double?
            for _ in 0..<600 {
                let p = s.progress
                if s.step(1.0 / 60) { settledFrom = p; break }
            }
            let from = try #require(settledFrom)
            #expect(abs(from - s.progress) * ppu < 0.5)
        }
        #expect(TabZoomState.restDistance * 680 < 0.25)
    }

    /// Safari's curves land monotonically: no step back in the last frames
    /// (zoom in) and an overshoot that eases back instead of holding then
    /// dropping (zoom out).
    @Test func curveTailsAreMonotone() {
        let zin = SafariCurve.zoomIn.samples.suffix(8)
        for (a, b) in zip(zin, zin.dropFirst()) { #expect(b >= a) }
        let out = SafariCurve.zoomOut.samples
        let peak = out.firstIndex(of: out.max()!)!
        let back = out[peak...]
        for (a, b) in zip(back, back.dropFirst()) { #expect(b <= a) }
        for (a, b) in zip(out.suffix(12), out.suffix(11)) { #expect(abs(a - b) * 680 < 0.5) }
    }
}

#if os(iOS)
/// The zoom's card end reads the grid's place from its scroll offset (never
/// a frame read through the grid's zoom scale), and a jump set before the
/// zoom moves it at once.
@MainActor
struct GridScrollOriginTests {
    @Test func screenOriginComesFromTheScrollOffset() {
        let t = GridScrollTracker()
        #expect(t.screenOrigin == .zero)
        t.apply(.init(offset: 300, insetTop: 0, offsetX: 0))
        #expect(t.screenOrigin == CGPoint(x: 0, y: -300))
        // Content inset: offset 62 counted from an inset of 62 is content y 0 at the screen's top.
        t.apply(.init(offset: 62, insetTop: 62, offsetX: 0))
        #expect(t.screenOrigin == .zero)
        t.offset = 500
        #expect(t.screenOrigin == CGPoint(x: 0, y: -438))
    }
}
#endif
