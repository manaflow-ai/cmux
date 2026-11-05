import AppKit
import Testing
@testable import MessagesLabHome

/// Every Home bubble variant draws one shared outline, `BubblePath.balloon`, and changes only its
/// fill or stroke (Lawrence 2026-10-20: "roundness of this is very bad; generally bubbles should
/// reuse code better"). Each test draws a variant with the real renderer into a bitmap and
/// compares the pixels it covers with the pixels the shared outline covers: a normal bubble, a
/// group chat bubble (indented beside an avatar), the pressed highlight over it, and a quoted
/// root above a reply. The old quote, a 1 pt outline with a full-size tail on a 24 pt body,
/// covered almost none of the shared outline's pixels.
@MainActor @Suite(.serialized) struct BubbleSharedShapeTests {
    static let canvas = CGSize(width: 700, height: 140)

    /// A bitmap drawn y-down at 2x in sRGB, cleared to opaque `background`.
    private func render(background: NSColor = Fixture.background, _ draw: (CGContext) -> Void) -> [UInt8] {
        let w = Int(Self.canvas.width * 2), h = Int(Self.canvas.height * 2)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 2, y: -2)
            ContextScope.run(ctx) {
                background.setFill()
                ctx.fill(CGRect(origin: .zero, size: Self.canvas))
                draw(ctx)
            }
        }
        return data
    }

    /// The pixels where `a` and `b` differ by more than `threshold` in any channel.
    private func changed(_ a: [UInt8], _ b: [UInt8], threshold: Int) -> Set<Int> {
        var out = Set<Int>()
        var i = 0
        while i < a.count {
            if abs(Int(a[i]) - Int(b[i])) > threshold || abs(Int(a[i + 1]) - Int(b[i + 1])) > threshold
                || abs(Int(a[i + 2]) - Int(b[i + 2])) > threshold { out.insert(i / 4) }
            i += 4
        }
        return out
    }

    /// The pixels the shared outline covers (filled black on white).
    private func sharedCoverage(_ path: UIBezierPath) -> Set<Int> {
        let blank = render(background: .white) { _ in }
        let filled = render(background: .white) { _ in NSColor.black.setFill(); path.fill() }
        return changed(blank, filled, threshold: 127)
    }

    /// `covered` matches the shared outline's pixels up to antialiased edge pixels.
    private func expectSameShape(_ covered: Set<Int>, _ shared: Set<Int>, _ what: String) {
        let mismatch = covered.symmetricDifference(shared).count
        #expect(!shared.isEmpty)
        #expect(Double(mismatch) <= 0.06 * Double(shared.count),
                "\(what): \(mismatch) of \(shared.count) pixels differ from the shared bubble outline")
    }

    private func row(lines: Int, tail: Bool, indent: CGFloat = 0) -> PartRow {
        var p = PartRow(ref: PartRef(messageId: "m", partIndex: 0), part: .text("x", runs: []), outgoing: false, tail: tail,
                        reactions: [], failed: false,
                        size: CGSize(width: 220, height: Fixture.lineHeight * CGFloat(lines) + 2 * Fixture.bubblePadY),
                        text: nil, connectorRoot: nil)
        p.cmuxIndent = indent
        return p
    }

    @Test(arguments: [(1, true, 0), (2, true, 0), (1, false, 0), (2, false, 0), (1, true, 28), (2, true, 28)] as [(Int, Bool, CGFloat)])
    func bubbleAndItsHighlightAreTheSharedShape(lines: Int, tail: Bool, indent: CGFloat) {
        let p = row(lines: lines, tail: tail, indent: indent)
        let frame = CGRect(x: p.cmuxBodyX(rightEdge: Fixture.rightEdge), y: 30, width: p.size.width, height: p.size.height)
        let blank = render { _ in }
        let plain = render { ctx in PartRenderer.draw(ctx, row: p, body: frame, windowY: 0, highlight: false) }
        let lit = render { ctx in PartRenderer.draw(ctx, row: p, body: frame, windowY: 0, highlight: true) }
        let shared = sharedCoverage(BubblePath.balloon(frame: frame, row: p))
        let name = "\(lines)-line bubble, tail \(tail), indent \(indent)"
        expectSameShape(changed(blank, plain, threshold: 6), shared, name)
        expectSameShape(changed(plain, lit, threshold: 4), shared, name + " highlight")
    }

    /// The Chief's quoted root is filled with its quote outline (`ThreadPreview.outline`); my root is that outline
    /// stroked (HomeReplyQuoteParityTests), so only the filled side is compared here.
    @Test(arguments: [(false, false), (false, true)])
    func quotedRootIsTheSharedShape(outgoing: Bool, long: Bool) {
        let text = long ? "Reply-to-conversation UI is very bad. It does not match my message at all. The threads don't look very good and it's not rounded properly at all."
            : "Reply-to-conversation UI is very bad."
        let pv = ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []), count: 0,
                                    outgoing: outgoing, width: Fixture.windowWidth)
        let box = outgoing
            ? CGRect(x: Fixture.rightEdge - pv.box.width, y: 20, width: pv.box.width, height: pv.box.height)
            : CGRect(x: Fixture.leftEdge, y: 20, width: pv.box.width, height: pv.box.height)
        let blank = render { _ in }
        let drawn = render { ctx in
            if outgoing {
                PartRenderer.drawOutgoingThreadPreview(ctx, pv, top: 20, rightEdge: Fixture.rightEdge)
            } else {
                PartRenderer.drawThreadPreview(ctx, pv, top: 20, width: Fixture.windowWidth)
            }
        }
        // Only the quote itself: the stub and "N Replies" lie under it.
        let rows = Int(box.minY * 2)..<Int(box.maxY * 2), w = Int(Self.canvas.width * 2)
        let covered = changed(blank, drawn, threshold: 4).filter { rows.contains($0 / w) }
        let shared = sharedCoverage(pv.outline(in: box))
        expectSameShape(covered, shared, "quote, outgoing \(outgoing), long \(long)")
    }
}
