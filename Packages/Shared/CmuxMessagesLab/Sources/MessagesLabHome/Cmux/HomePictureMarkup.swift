import AppKit
import CoreGraphics
import CoreText
import Foundation

/// cmux: the marks drawn on a picture in the large picture viewer (``HomePictureViewer``): arrows, boxes, pen
/// strokes and words, in the picture's own pixels (y down from its top), so the same marks draw on screen at any
/// zoom and into the exported picture at full size. Values only; any thread.
struct HomePictureMarkup: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        case box(CGRect)
        case pen([CGPoint])
        case text(at: CGPoint, String)
    }

    private(set) var marks: [Mark] = []

    mutating func add(_ mark: Mark) { marks.append(mark) }
    mutating func undo() { if !marks.isEmpty { marks.removeLast() } }

    /// The marks' red (fixed sRGB: a system colour resolved off the main thread can be its light variant).
    static let ink = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)

    /// The stroke width for a picture of `size` pixels: thick enough to read on a 2x screenshot.
    static func lineWidth(_ size: CGSize) -> CGFloat { max(3, min(size.width, size.height) / 150).rounded() }
    /// The words' size for a picture of `size` pixels.
    static func fontSize(_ size: CGSize) -> CGFloat { max(16, min(size.width, size.height) / 22).rounded() }

    /// `image` with the marks drawn over it, at its own size; nil when no bitmap could be made.
    func render(onto image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        // The marks are y down: flip once for all of them.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, pictureSize: size)
        return ctx.makeImage()
    }

    /// Draws the marks into `ctx`, already in the picture's pixels with y down.
    func draw(in ctx: CGContext, pictureSize size: CGSize) {
        for mark in marks { Self.draw(mark, in: ctx, pictureSize: size) }
    }

    /// Draws one mark (also the one being drawn, before it is added) into a y-down `ctx` in picture pixels.
    static func draw(_ mark: Mark, in ctx: CGContext, pictureSize size: CGSize) {
        let width = lineWidth(size)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch mark {
        case let .box(rect):
            ctx.stroke(rect.standardized)
        case let .pen(points):
            guard let first = points.first else { return }
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            if points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            ctx.strokePath()
        case let .arrow(from, to):
            let dx = to.x - from.x, dy = to.y - from.y
            let length = hypot(dx, dy)
            guard length > 0.5 else { return }
            let head = min(length * 0.45, width * 5)
            let angle = atan2(dy, dx)
            let base = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
            ctx.move(to: from)
            ctx.addLine(to: base)
            ctx.strokePath()
            let spread: CGFloat = .pi / 7
            ctx.move(to: to)
            ctx.addLine(to: CGPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head))
            ctx.addLine(to: CGPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head))
            ctx.closePath()
            ctx.fillPath()
        case let .text(at, words):
            guard !words.isEmpty else { return }
            // HomeFonts: one held instance per size (a font made and dropped off main can come back nil, cx-qpqs).
            let font = HomeFonts.system(ofSize: fontSize(size), weight: .bold) as CTFont
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            ]))
            // A white halo under the red words keeps them readable on any picture.
            let halo = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -fontSize(size) / 6,
            ]))
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let ascent = CTFontGetAscent(font)
            ctx.textPosition = CGPoint(x: at.x, y: at.y + ascent)
            CTLineDraw(halo, ctx)
            ctx.textPosition = CGPoint(x: at.x, y: at.y + ascent)
            CTLineDraw(line, ctx)
        }
    }
}
