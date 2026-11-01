import AppKit
@testable import MessagesLabHome
import Testing

/// The thread preview above a reply (Lawrence 2026-10-27, the 5:54 PM screenshot): my own root is an
/// outlined blue bubble at the right edge with "N Replies" in blue under it, not a blue fill. The
/// Chief's root (a gray bubble) keeps its gray fill and never shows the blue. These tests draw the
/// preview with the real renderer into a bitmap and read its pixels.
@MainActor @Suite(.serialized) struct HomeThreadRootOutlineTests {
    struct Bitmap {
        var data: [UInt8]
        var width: Int, height: Int
        /// The pixel at a y-down point (2x), as 0...255 RGB.
        func rgb(_ p: CGPoint) -> (Double, Double, Double) {
            let x = min(width - 1, max(0, Int(p.x * 2))), y = min(height - 1, max(0, Int(p.y * 2)))
            let i = (y * width + x) * 4
            return (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
        }
    }

    static let canvas = CGSize(width: 1700, height: 120)
    static let top: CGFloat = 20
    static let width: CGFloat = 628

    private func srgb(_ c: NSColor) -> (Double, Double, Double) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (Double(s.redComponent * 255), Double(s.greenComponent * 255), Double(s.blueComponent * 255))
    }

    private func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    /// Draws `pv` as the transcript draws it, on the transcript background, at 2x in sRGB. The drawing snaps
    /// to the bitmap's 2x pixels (`Fixture.withRenderScale(2)`, as a view scopes its own scale): outside a scope
    /// it snaps to the process fallback, which any Home pane in the same test process sets to its screen's
    /// scale. On a 1x CI mini the outline then snapped half a point left of `box.minX + 0.5` and that pixel read
    /// the background (24, 24, 24) in the full run, though the outline was drawn.
    private func render(_ pv: ThreadPreview) -> (Bitmap, CGRect) {
        Fixture.withRenderScale(2) { renderAt2x(pv) }
    }

    private func renderAt2x(_ pv: ThreadPreview) -> (Bitmap, CGRect) {
        let w = Int(Self.canvas.width * 2), h = Int(Self.canvas.height * 2)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let rightEdge = Metrics(width: Self.width).rightEdge
        let box = pv.outgoing
            ? CGRect(x: rightEdge - pv.box.width, y: Self.top, width: pv.box.width, height: pv.box.height)
            : CGRect(x: Fixture.leftEdge, y: Self.top, width: pv.box.width, height: pv.box.height)
        data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 2, y: -2)
            ContextScope.run(ctx) {
                Fixture.background.setFill()
                ctx.fill(CGRect(origin: .zero, size: Self.canvas))
                if pv.outgoing {
                    PartRenderer.drawOutgoingThreadPreview(ctx, pv, top: Self.top, rightEdge: rightEdge)
                } else {
                    PartRenderer.drawThreadPreview(ctx, pv, top: Self.top, width: Self.width)
                }
            }
        }
        return (Bitmap(data: data, width: w, height: h), box)
    }

    private func preview(_ text: String, outgoing: Bool, count: Int = 3) -> ThreadPreview {
        Fixture.withRenderScale(2) {
            ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []), count: count,
                               outgoing: outgoing, width: Self.width)
        }
    }

    static let short = "find an iPhone duo i can pick up from store asap"

    @Test func myRootIsAnOutlinedBlueBubbleNotAFill() {
        checkMyRootOutline()
    }

    /// A guard on this suite, not the product: the same check when the scale around it is 1x, as in the full
    /// run on a 1x CI mini (a Home pane there sets the process fallback; a 1x scope here, so no other test sees
    /// it). It passes because `render` and `preview` draw in their own 2x scope; without that scope it was red
    /// (edge 224 from blue, PR 26884's first commit), the same red as the full run.
    @Test func theOutlineCheckDrawsAt2xWhateverTheScaleAroundIt() {
        Fixture.withRenderScale(1) { checkMyRootOutline() }
    }

    private func checkMyRootOutline() {
        let (bmp, box) = render(preview(Self.short, outgoing: true))
        let bg = srgb(Fixture.background)
        let blue = srgb(Fixture.quoteOutline)
        // Inside the bubble, clear of the text: the background, not a blue fill.
        let inside = bmp.rgb(CGPoint(x: box.minX + 3, y: box.midY))
        #expect(distance(inside, bg) <= 12, "my root is filled \(inside); it should be an outline on \(bg)")
        // On the outline at the left end: Messages' quote blue (2026-10-28 reference).
        let edge = bmp.rgb(CGPoint(x: box.minX + 0.5, y: box.midY))
        #expect(distance(edge, blue) <= 24, "my root's outline is \(edge), not blue \(blue)")
    }

    @Test func myRepliesLabelIsBoldBlueUnderTheRoot() {
        let (bmp, box) = render(preview(Self.short, outgoing: true, count: 6))
        let tint = srgb(Fixture.repliesTint)
        var best = Double.infinity
        var y = box.maxY + 4
        while y < box.maxY + 16 {
            var x = box.maxX - 80
            while x < box.maxX { best = min(best, distance(bmp.rgb(CGPoint(x: x, y: y)), tint)); x += 0.5 }
            y += 0.5
        }
        #expect(best <= 40, "no full-strength blue N Replies label under my root; closest pixel was \(best) away")
    }

    @Test func chiefsRootShowsNoBlue() {
        let (bmp, box) = render(preview(Self.short, outgoing: false))
        let blue = srgb(Fixture.outgoing)
        var closest = Double.infinity
        var y = box.minY
        while y < box.maxY {
            var x = box.minX
            while x < box.maxX { closest = min(closest, distance(bmp.rgb(CGPoint(x: x, y: y)), blue)); x += 1 }
            y += 1
        }
        #expect(closest > 60, "the Chief's root draws blue (closest pixel \(closest) from blue)")
    }
}
