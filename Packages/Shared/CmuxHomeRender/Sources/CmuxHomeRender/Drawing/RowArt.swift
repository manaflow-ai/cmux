import CoreGraphics
import CoreText

/// Where a row's bitmap sits and what it draws. The bitmap is drawn in its
/// own coordinates and holds only content, so its pixels never depend on the
/// viewport width: a resize moves the bitmap and keeps it.
@MainActor
enum RowArt {
    /// Horizontal padding around single-line captions (glyph overhang).
    static let captionPad: CGFloat = 2

    static var separatorFonts: (CTFont, CTFont) { (Fonts.system(Style.captionSize, .semibold), Fonts.system(Style.captionSize)) }
    static var unsentFont: CTFont { Fonts.system(11) }
    static var labelFont: CTFont { Fonts.system(10, .medium) }
    static var receiptFont: CTFont { Fonts.system(Style.captionSize, .semibold) }

    /// The typing bubble without its dots (the dots are animated layers).
    static let typingBubble = CGRect(x: 20, y: Style.rowMargin + 4, width: 44, height: 27.5)
    static let typingWidth: CGFloat = 140

    static func typingDotCenter(_ i: Int) -> CGPoint {
        CGPoint(x: typingBubble.minX + 12.25 + CGFloat(i) * 9.5, y: typingBubble.midY)
    }

    /// Body rect of a part row in row coordinates.
    static func bodyRect(_ spec: RowSpec, metrics: Metrics) -> CGRect {
        guard let p = spec.partRow else { return .zero }
        let x = p.outgoing ? metrics.rightEdge - p.size.width : Style.leftEdge
        return CGRect(x: x, y: Style.rowMargin, width: p.size.width, height: p.bodySize.height)
    }

    /// Body rect of a part row in its bitmap's coordinates.
    static func localBody(_ p: PartRow) -> CGRect {
        CGRect(x: Style.artLeft, y: Style.rowMargin, width: p.size.width, height: p.bodySize.height)
    }

    private static func separatorWidth(_ bold: String, _ rest: String) -> CGFloat {
        let (b, r) = separatorFonts
        return TextDraw.width(bold, font: b, kern: Style.captionKern) + TextDraw.width(" " + rest, font: r, kern: Style.captionKern)
    }

    /// The bitmap's frame in row coordinates.
    static func frame(_ spec: RowSpec, metrics: Metrics) -> CGRect {
        let height = spec.height + 2 * Style.rowMargin
        let pad = captionPad
        switch spec.kind {
        case .part(let p):
            let body = bodyRect(spec, metrics: metrics)
            return CGRect(x: body.minX - Style.artLeft, y: 0, width: p.size.width + Style.artLeft + Style.artRight, height: height)
        case .separator(let bold, let rest):
            let w = separatorWidth(bold, rest)
            return CGRect(x: metrics.centerX - w / 2 - pad, y: 0, width: w + 2 * pad, height: height)
        case .unsent(let outgoing):
            let w = TextDraw.width(outgoing ? HomeStrings.unsentMine : HomeStrings.unsentTheirs, font: unsentFont)
            return CGRect(x: metrics.centerX + 0.1 - w / 2 - pad, y: 0, width: w + 2 * pad, height: height)
        case .failedLabel(let text):
            let w = TextDraw.width(text, font: labelFont)
            return CGRect(x: metrics.receiptRight - w - pad, y: 0, width: w + 2 * pad, height: height)
        case .receipt(let text):
            let w = TextDraw.width(text, font: receiptFont, kern: Style.captionKern)
            return CGRect(x: metrics.receiptRight - w - pad, y: 0, width: w + 2 * pad, height: height)
        case .typing:
            return CGRect(x: 0, y: 0, width: typingWidth, height: height)
        }
    }

    /// Draws the row's content into a context of `frame(...).size`.
    static func draw(_ spec: RowSpec, palette: HomePalette, _ ctx: CGContext) {
        let top = Style.rowMargin
        let x = captionPad
        let secondary = palette.secondaryText.cgColor
        switch spec.kind {
        case .part(let p):
            PartDrawing.draw(ctx, p, body: localBody(p), palette: palette)
        case .separator(let bold, let rest):
            let (b, r) = separatorFonts
            TextDraw.line(bold, font: b, color: secondary, x: x, baseline: top + 27.5, in: ctx, kern: Style.captionKern)
            let bw = TextDraw.width(bold, font: b, kern: Style.captionKern)
            TextDraw.line(" " + rest, font: r, color: secondary, x: x + bw, baseline: top + 27.5, in: ctx, kern: Style.captionKern)
        case .unsent(let outgoing):
            TextDraw.line(outgoing ? HomeStrings.unsentMine : HomeStrings.unsentTheirs, font: unsentFont, color: secondary,
                          x: x, baseline: top + 12, in: ctx)
        case .failedLabel(let text):
            TextDraw.line(text, font: labelFont, color: palette.failure.cgColor, x: x, baseline: top + 11, in: ctx)
        case .receipt(let text):
            TextDraw.line(text, font: receiptFont, color: secondary, x: x, baseline: top + 14, in: ctx, kern: Style.captionKern)
        case .typing:
            let b = typingBubble
            let fill = palette.incomingBubble.cgColor
            Canvas.fill(ctx, RoundedRect.path(b, radius: b.height / 2), fill)
            ctx.fillEllipse(in: CGRect(x: 20.5, y: b.maxY - 7, width: 9, height: 9))
            ctx.fillEllipse(in: CGRect(x: 16.5, y: b.maxY + 1, width: 5, height: 5))
        }
    }
}
