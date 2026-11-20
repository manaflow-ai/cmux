import CoreGraphics
import CoreText

/// Drawing of one text bubble: the incoming fill (the outgoing fill is the
/// row's gradient layer, so it can shade with the row's viewport position),
/// the text, the failed badge and the tapback badges. Nonisolated: it runs
/// off the main actor inside `RowBitmaps`.
enum PartDrawing {
    static func draw(_ ctx: CGContext, _ p: PartRow, body: CGRect, palette: HomePalette) {
        // A media bubble's picture and placeholder are the row's media layer.
        if !p.outgoing, p.media == nil {
            Canvas.fill(ctx, BubblePath.make(body: body, outgoing: false, tail: p.tail), palette.incomingBubble.cgColor)
        }
        switch p.content {
        case .text(let text): drawText(ctx, text, in: body, outgoing: p.outgoing, palette: palette)
        case .file(let file): AttachmentDrawing.drawChip(ctx, file, in: body, outgoing: p.outgoing, palette: palette)
        case .media: break
        }
        if p.failed { drawFailedBadge(ctx, body: body, palette: palette) }
        drawReactions(ctx, p.reactions, body: body, outgoing: p.outgoing, palette: palette)
    }

    static func drawText(_ ctx: CGContext, _ tl: TextLayout, in body: CGRect, outgoing: Bool, palette: HomePalette) {
        let color = (outgoing ? palette.outgoingText : palette.incomingText).cgColor
        let attr = tl.attributed(font: Style.bodyFont, color: color)
        let hard = outgoing ? Style.hardBreakAdvance : Style.lineHeight
        for (i, line) in tl.lines.enumerated() where line.range.length > 0 {
            let ct = CTLineCreateWithAttributedString(attr.attributedSubstring(from: line.range))
            TextDraw.draw(ct, x: body.minX + Style.bubblePadX, baseline: body.minY + Style.textBaseline + tl.lineOffset(i, hard: hard), ctx)
        }
    }

    /// A red disc with "!" left of a send the owner refused.
    static func drawFailedBadge(_ ctx: CGContext, body: CGRect, palette: HomePalette) {
        let c = CGPoint(x: body.minX - 14, y: body.midY)
        ctx.setFillColor(palette.failure.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
        let f = Fonts.system(12, .bold)
        TextDraw.line("!", font: f, color: palette.outgoingText.cgColor, x: c.x - TextDraw.width("!", font: f) / 2,
                      baseline: c.y + 4.5, in: ctx)
    }

    /// Tapback badges on the bubble's top outer corner: a 27.5 pt disc whose
    /// center is 2 pt inside the corner and 8.25 pt above the top edge, two
    /// tail circles toward the outside, the glyph inside. Mine use the
    /// outgoing colour. Further badges stack 12 pt toward the middle.
    static func drawReactions(_ ctx: CGContext, _ badges: [ReactionBadge], body: CGRect, outgoing: Bool, palette: HomePalette) {
        let side: CGFloat = outgoing ? -1 : 1
        let d: CGFloat = 27.5
        for (i, badge) in badges.enumerated().reversed() {
            let cx = (outgoing ? body.minX + 2 : body.maxX - 2) - side * CGFloat(i) * 12
            let c = CGPoint(x: cx, y: body.minY - 8.25)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1.5, color: HomeColor.gray255(0, alpha: 0.35).cgColor)
            ctx.setFillColor((badge.mine ? palette.outgoing(at: 1) : palette.badge).cgColor)
            if i == 0 {
                ctx.fillEllipse(in: CGRect(x: c.x + side * 8.5 - 4, y: c.y + 13.25 - 4, width: 8, height: 8))
                ctx.fillEllipse(in: CGRect(x: c.x + side * 14.25 - 2, y: c.y + 19.25 - 2, width: 4, height: 4))
            }
            ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            ctx.restoreGState()
            let f = Fonts.system(15)
            let w = TextDraw.width(badge.glyph, font: f)
            TextDraw.line(badge.glyph, font: f, color: palette.outgoingText.cgColor, x: c.x - w / 2, baseline: c.y + 5.5, in: ctx)
        }
    }
}
