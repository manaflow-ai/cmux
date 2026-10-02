import CoreGraphics
import CoreText
import Foundation

/// The inputs of a row's drawing.
nonisolated struct DrawSignature: Hashable, Sendable {
    var kind: TranscriptRowKind
    var width: CGFloat
    var height: CGFloat
}

/// Everything a row's drawing depends on: equal keys reuse a raster.
nonisolated struct RasterKey: Hashable, Sendable {
    var row: DrawSignature
    var colors: TranscriptColors
    var scale: CGFloat
    /// The geometry fields drawing reads (not the window width).
    var style: [CGFloat]

    init(row: TranscriptRow, geometry g: TranscriptGeometry, colors: TranscriptColors, scale: CGFloat) {
        self.row = row.drawSignature
        self.colors = colors
        self.scale = scale
        style = [g.fontSize, g.captionSize, g.insetX, g.insetY]
    }
}

/// Draws one transcript row into a BGRA bitmap (any thread). The canvas is
/// the row frame plus ``pad`` on every side (tails, badges, the failed mark),
/// drawn top-down in points at `scale`.
nonisolated enum RowPainter {
    static func pad(_ g: TranscriptGeometry) -> CGFloat { (g.lineHeight * 1.8).rounded(.up) }

    static func image(_ row: TranscriptRow, geometry g: TranscriptGeometry, colors c: TranscriptColors, scale: CGFloat,
                      space: CGColorSpace) -> CGImage? {
        let pad = pad(g)
        let size = CGSize(width: row.width + 2 * pad, height: row.height + 2 * pad)
        let pw = max(1, Int((size.width * scale).rounded(.up))), ph = max(1, Int((size.height * scale).rounded(.up)))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: info) else { return nil }
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        let body = CGRect(x: pad, y: pad, width: row.width, height: row.height)
        draw(row, body: body, geometry: g, colors: c, in: ctx)
        return ctx.makeImage()
    }

    static func draw(_ row: TranscriptRow, body: CGRect, geometry g: TranscriptGeometry, colors c: TranscriptColors,
                     in ctx: CGContext) {
        switch row.kind {
        case .separator(let day, let time):
            let dayWidth = TextFormatter.lineWidth(day, size: g.captionSize, emphasized: true)
            line(day, size: g.captionSize, emphasized: true, color: c.textSecondary, x: body.minX, in: body, ctx)
            line(" " + time, size: g.captionSize, emphasized: false, color: c.textSecondary, x: body.minX + dayWidth,
                 in: body, ctx)
        case .label(let text, let detail, _, let tone):
            let color = tone == .danger ? c.danger : c.textSecondary
            let width = TextFormatter.lineWidth(text, size: g.captionSize, emphasized: true)
            line(text, size: g.captionSize, emphasized: true, color: color, x: body.minX, in: body, ctx)
            if let detail {
                line(" " + detail, size: g.captionSize, emphasized: false, color: color, x: body.minX + width, in: body, ctx)
            }
        case .retracted(let text):
            line(text, size: g.captionSize, emphasized: false, color: c.textTertiary, x: body.minX, in: body, ctx)
        case .typing:
            ctx.addPath(BubbleShape.path(body, outgoing: false, tail: true, radius: g.bubbleRadius))
            ctx.setFillColor(c.incomingFill.cgColor)
            ctx.fillPath()
        case .bubble(let outgoing, let text, let mentions, let tail, let reactions, let failed):
            bubble(body, outgoing: outgoing, tail: tail, g: g, c: c, ctx)
            let color = outgoing ? c.outgoingText : c.textPrimary
            textBlock(text, mentions: mentions, color: color, in: body.insetBy(dx: g.insetX, dy: g.insetY), g: g, ctx)
            if !reactions.isEmpty { badges(reactions, body: body, outgoing: outgoing, g: g, c: c, ctx) }
            if failed { failedMark(body: body, g: g, c: c, ctx) }
        case .fallback(let outgoing, let text, let tail):
            ctx.addPath(BubbleShape.path(body, outgoing: outgoing, tail: tail, radius: g.bubbleRadius))
            ctx.setFillColor(c.cardFill.cgColor)
            ctx.fillPath()
            ctx.addPath(BubbleShape.path(body.insetBy(dx: 0.5, dy: 0.5), outgoing: outgoing, tail: tail,
                                         radius: g.bubbleRadius))
            ctx.setStrokeColor(c.cardStroke.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            textBlock(text, mentions: [], color: c.textSecondary, in: body.insetBy(dx: g.insetX, dy: g.insetY), g: g, ctx)
        case .work(_, let session, let status, let statusText, let preview, _):
            WorkCardPainter.draw(session: session, status: status, statusText: statusText, preview: preview, body: body,
                                 g: g, c: c, ctx)
        }
    }

    private static func bubble(_ body: CGRect, outgoing: Bool, tail: Bool, g: TranscriptGeometry, c: TranscriptColors,
                               _ ctx: CGContext) {
        ctx.addPath(BubbleShape.path(body, outgoing: outgoing, tail: tail, radius: g.bubbleRadius))
        ctx.setFillColor((outgoing ? c.outgoingFill : c.incomingFill).cgColor)
        ctx.fillPath()
    }

    /// Wrapped text in a y-down `rect` (CoreText lays out y-up, so the block is flipped locally).
    static func textBlock(_ text: String, mentions: [HomeMention], color: RGBA, in rect: CGRect, g: TranscriptGeometry,
                          _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        TextFormatter.draw(text, mentions: mentions, fontSize: g.fontSize, lineHeight: g.lineHeight, color: color.cgColor,
                           in: CGRect(x: rect.minX, y: 0, width: rect.width + 1, height: rect.height), context: ctx)
        ctx.restoreGState()
    }

    /// One line vertically centered in `box` (y-down), starting at `x`.
    static func line(_ text: String, size: CGFloat, emphasized: Bool, color: RGBA, x: CGFloat, in box: CGRect,
                     _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let baseline = box.height - TextFormatter.baseline(size: size, inLineOf: box.height)
        TextFormatter.drawLine(text, size: size, emphasized: emphasized, color: color.cgColor, x: x, baseline: baseline,
                               context: ctx)
        ctx.restoreGState()
    }

    /// Tapback badges on the bubble's top corner away from the sender's side, stacked.
    private static func badges(_ kinds: [String], body: CGRect, outgoing: Bool, g: TranscriptGeometry,
                               c: TranscriptColors, _ ctx: CGContext) {
        let d = g.lineHeight + 4
        let shown = Array(kinds.prefix(3))
        for (i, kind) in shown.enumerated().reversed() {
            let offset = CGFloat(i) * d * 0.55
            let cx = outgoing ? body.minX + d * 0.2 - offset : body.maxX - d * 0.2 + offset
            let circle = CGRect(x: cx - d / 2, y: body.minY - d * 0.6, width: d, height: d)
            ctx.setFillColor(c.badgeStroke.cgColor)
            ctx.fillEllipse(in: circle.insetBy(dx: -1.5, dy: -1.5))
            ctx.setFillColor(c.badgeFill.cgColor)
            ctx.fillEllipse(in: circle)
            let glyph = Self.glyph(kind)
            let size = g.captionSize
            let width = TextFormatter.lineWidth(glyph, size: size, emphasized: false)
            line(glyph, size: size, emphasized: false, color: c.textPrimary, x: circle.midX - width / 2, in: circle, ctx)
        }
    }

    /// The emoji for a tapback name; an emoji reaction draws as itself.
    static func glyph(_ kind: String) -> String {
        switch kind {
        case "love": "\u{2764}\u{FE0F}"
        case "like": "\u{1F44D}"
        case "dislike": "\u{1F44E}"
        case "laugh": "\u{1F602}"
        case "emphasize": "\u{203C}\u{FE0F}"
        case "question": "\u{2753}"
        default: kind
        }
    }

    private static func failedMark(body: CGRect, g: TranscriptGeometry, c: TranscriptColors, _ ctx: CGContext) {
        let d = g.lineHeight
        let circle = CGRect(x: body.minX - d - g.insetY, y: body.midY - d / 2, width: d, height: d)
        ctx.setFillColor(c.danger.cgColor)
        ctx.fillEllipse(in: circle)
        let width = TextFormatter.lineWidth("!", size: g.captionSize, emphasized: true)
        line("!", size: g.captionSize, emphasized: true, color: c.background, x: circle.midX - width / 2, in: circle, ctx)
    }
}
