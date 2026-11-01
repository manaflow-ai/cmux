import AppKit
import Testing
@testable import MessagesLabHome

/// The quoted root above a reply in the Home chat is a copy of the real bubble it quotes
/// (Lawrence 2026-10-20: "Reply-to-conversation UI is very bad. It does not match my message
/// at all ... It's not rounded properly at all"). The old quote was a 1 pt outline with blue
/// 10 pt text and a full-size tail glued to a 24 pt body. These tests draw a quote with the
/// real row renderer into a bitmap and read its pixels: the quote must be filled with its
/// source's bubble colour (faded by `ThreadPreview.quoteOpacity`), carry the source's text
/// colour, have rounded ends and no tail, at every transcript width, light and dark.
@MainActor @Suite(.serialized) struct ThreadQuoteBubbleTests {
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

    private func srgb(_ c: NSColor) -> (Double, Double, Double) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (Double(s.redComponent * 255), Double(s.greenComponent * 255), Double(s.blueComponent * 255))
    }

    private func blend(_ a: (Double, Double, Double), over b: (Double, Double, Double), alpha: Double) -> (Double, Double, Double) {
        (a.0 * alpha + b.0 * (1 - alpha), a.1 * alpha + b.1 * (1 - alpha), a.2 * alpha + b.2 * (1 - alpha))
    }

    private func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    /// Draws `pv` as a row draws it, on the transcript background, at 2x in sRGB.
    private func render(_ pv: ThreadPreview, width: CGFloat) -> (Bitmap, CGRect) {
        let w = Int(Self.canvas.width * 2), h = Int(Self.canvas.height * 2)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let rightEdge = Metrics(width: width).rightEdge
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
                    PartRenderer.drawThreadPreview(ctx, pv, top: Self.top, width: width)
                }
            }
        }
        return (Bitmap(data: data, width: w, height: h), box)
    }

    private func preview(_ text: String, outgoing: Bool, width: CGFloat) -> ThreadPreview {
        ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []), count: 0,
                           outgoing: outgoing, width: width)
    }

    static let short = "Reply-to-conversation UI is very bad."
    static let long = "Reply-to-conversation UI is very bad. It does not match my message at all. The threads don't look very good and it's not rounded properly at all."

    @Test(arguments: [(true, false), (false, false), (true, true), (false, true)])
    func quoteIsFilledWithItsSourceBubbleColour(outgoing: Bool, light: Bool) {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let pv = preview(Self.short, outgoing: outgoing, width: 628)
        let (bmp, box) = render(pv, width: 628)
        let bg = srgb(Fixture.background)
        // My root is an outline (2026-10-27/28 references): inside it is the background. The Chief's keeps its faded fill.
        let fill = outgoing ? bg : blend(srgb(Fixture.incoming), over: bg, alpha: Double(ThreadPreview.quoteOpacity))
        // Inside the left end, clear of the text: the bubble's own fill, faded.
        let inside = bmp.rgb(CGPoint(x: box.minX + 4, y: box.midY))
        #expect(distance(inside, fill) <= 10, "quote body \(inside) should be its source fill \(fill)")
        // The text: Messages' quote blue for mine, the bubble's ink (faded) for the Chief's.
        let ink = outgoing ? srgb(Fixture.quoteText) : blend(srgb(Fixture.incomingText), over: bg, alpha: Double(ThreadPreview.quoteOpacity))
        var best = Double.infinity
        var y = box.minY + 4
        while y < box.maxY - 4 {
            var x = box.minX + 10
            while x < box.maxX - 10 { best = min(best, distance(bmp.rgb(CGPoint(x: x, y: y)), ink)); x += 0.5 }
            y += 0.5
        }
        #expect(best <= 40, "no glyph pixel near the source text colour \(ink); closest was \(best) away")
    }

    @Test(arguments: [360, 628, 1000, 1600] as [CGFloat])
    func quoteHasRoundedEndsAndNoTailAtEveryWidth(width: CGFloat) {
        for outgoing in [true, false] {
            for text in [Self.short, Self.long] {
                let pv = preview(text, outgoing: outgoing, width: width)
                let (bmp, box) = render(pv, width: width)
                let bg = srgb(Fixture.background)
                // Rounded: the box's corner pixel is background, the middle of each end is filled.
                for corner in [CGPoint(x: box.minX + 1, y: box.minY + 1), CGPoint(x: box.maxX - 1, y: box.minY + 1),
                               CGPoint(x: box.minX + 1, y: box.maxY - 1), CGPoint(x: box.maxX - 1, y: box.maxY - 1)] {
                    #expect(distance(bmp.rgb(corner), bg) <= 3, "corner \(corner) of \(box) is not rounded (w \(width), out \(outgoing))")
                }
                let inset: CGFloat = outgoing ? 0.5 : 1.5 // my root's 1 pt outline, the Chief's fill
                for end in [CGPoint(x: box.minX + inset, y: box.midY), CGPoint(x: box.maxX - inset, y: box.midY)] {
                    #expect(distance(bmp.rgb(end), bg) > 6, "end \(end) of \(box) is not filled (w \(width), out \(outgoing))")
                }
                // Its small tail hangs under the body (HomeReplyQuoteParityTests); nothing is drawn past the body's end.
                let tail = outgoing ? CGPoint(x: box.maxX + 3, y: box.maxY - 1.5) : CGPoint(x: box.minX - 3, y: box.maxY - 1.5)
                #expect(distance(bmp.rgb(tail), bg) <= 3, "quote draws a tail at \(tail) (w \(width), out \(outgoing))")
            }
        }
    }
}
