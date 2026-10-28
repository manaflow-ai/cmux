import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// `PanVisibilitySpan`: a strip pan inside the span brings no pane into or out of
/// the viewport or the keep-alive band, so the visibility pass it skips would have reported nothing.
struct PanVisibilitySpanTests {
    private static let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

    /// The membership the visibility pass computes: overlap wider and taller than half a point.
    private static func isIn(_ frame: CGRect, _ rect: CGRect) -> Bool {
        let overlap = frame.intersection(rect)
        return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
    }

    @Test func aPaneInsideTheViewportBoundsTheSpanAtItsEdgesHalfAPointIn() {
        let span = PanVisibilitySpan(frames: [CGRect(x: 200, y: 0, width: 600, height: 800)], rects: [Self.viewport])
        // Its right edge reaches the viewport's left edge + 0.5 at -799.5; its left edge the right edge - 0.5 at +799.5.
        #expect(span == PanVisibilitySpan(lower: -799.5, upper: 799.5))
        #expect(span.contains(799) && !span.contains(799.5) && span.contains(-799) && !span.contains(-799.5))
    }

    @Test func aPaneOffToTheRightEntersOnceItsLeftEdgePassesTheViewportEdge() {
        let span = PanVisibilitySpan(frames: [CGRect(x: 1100, y: 0, width: 600, height: 800)], rects: [Self.viewport])
        #expect(span.upper == .infinity)
        #expect(span.lower == -100.5, "it shows once it moves 100.5 pt left")
    }

    @Test func aPaneOutsideTheRectVerticallyNeverBoundsIt() {
        let span = PanVisibilitySpan(frames: [CGRect(x: 200, y: 900, width: 600, height: 300)], rects: [Self.viewport])
        #expect(span == .unbounded)
    }

    @Test func aPaneExactlyOnAnEdgeAllowsNoPan() {
        let span = PanVisibilitySpan(frames: [CGRect(x: 999.5, y: 0, width: 600, height: 800)], rects: [Self.viewport])
        #expect(!span.contains(0.01) && !span.contains(-0.01))
    }

    @Test func noDeltaInsideTheSpanChangesAnyPanesMembership() {
        // A seeded walk over strips of random columns, viewports and band, and deltas.
        var seed: UInt64 = 0x2026_1026
        func next() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)
        }
        let band = Self.viewport.insetBy(dx: -Self.viewport.width, dy: 0)
        for _ in 0..<200 {
            let frames = (0..<6).map { _ in
                CGRect(x: next() * 4000 - 2000, y: next() * 900 - 50, width: next() * 900 + 0.2, height: next() * 800 + 0.2)
            }
            let span = PanVisibilitySpan(frames: frames, rects: [Self.viewport, band])
            for _ in 0..<50 {
                let delta = next() * 3000 - 1500
                guard span.contains(delta) else { continue }
                for frame in frames {
                    let moved = frame.offsetBy(dx: delta, dy: 0)
                    #expect(Self.isIn(moved, Self.viewport) == Self.isIn(frame, Self.viewport), "\(frame) by \(delta)")
                    #expect(Self.isIn(moved, band) == Self.isIn(frame, band), "\(frame) by \(delta)")
                }
            }
        }
    }
}
