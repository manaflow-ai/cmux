import CoreGraphics
import CoreText
import Foundation

/// A compact card for an agent's work part: status dot, session name and
/// status on the first line, a one-line preview under it.
nonisolated enum WorkCardPainter {
    static func draw(session: String, status: HomeWorkStatus, statusText: String, preview: String?, body: CGRect,
                     g: TranscriptGeometry, c: TranscriptColors, _ ctx: CGContext) {
        let radius = min(g.bubbleRadius, body.height / 2) * 0.7
        ctx.addPath(BubbleShape.roundedRect(body, radius: radius))
        ctx.setFillColor(c.cardFill.cgColor)
        ctx.fillPath()
        ctx.addPath(BubbleShape.roundedRect(body.insetBy(dx: 0.5, dy: 0.5), radius: radius))
        ctx.setStrokeColor(c.cardStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let inner = body.insetBy(dx: g.insetX, dy: g.insetY)
        let first = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: g.lineHeight)
        let dot = g.captionSize * 0.6
        ctx.setFillColor(color(status, c).cgColor)
        ctx.fillEllipse(in: CGRect(x: first.minX, y: first.midY - dot / 2, width: dot, height: dot))

        let statusWidth = TextFormatter.lineWidth(statusText, size: g.captionSize, emphasized: false)
        let nameX = first.minX + dot + g.insetY
        let nameMax = first.maxX - statusWidth - g.insetX - nameX
        truncated(session, size: g.fontSize, emphasized: true, color: c.textPrimary, x: nameX, maxWidth: nameMax,
                  in: first, ctx)
        RowPainter.line(statusText, size: g.captionSize, emphasized: false, color: c.textSecondary,
                        x: first.maxX - statusWidth, in: first, ctx)
        if let preview, !preview.isEmpty {
            let second = CGRect(x: inner.minX, y: first.maxY, width: inner.width, height: g.captionLineHeight)
            truncated(preview, size: g.captionSize, emphasized: false, color: c.textSecondary, x: second.minX,
                      maxWidth: second.width, in: second, ctx)
        }
    }

    static func color(_ status: HomeWorkStatus, _ c: TranscriptColors) -> RGBA {
        switch status {
        case .running: c.attention
        case .done: c.success
        case .failed: c.danger
        case .waiting: c.textTertiary
        }
    }

    /// One line cut with an ellipsis at `maxWidth`, vertically centered in `box` (y-down).
    private static func truncated(_ text: String, size: CGFloat, emphasized: Bool, color: RGBA, x: CGFloat,
                                  maxWidth: CGFloat, in box: CGRect, _ ctx: CGContext) {
        let font = TextFormatter.font(size: size, emphasized: emphasized)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let single = text.replacingOccurrences(of: "\n", with: " ")
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: single, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
        let cut = CTLineCreateTruncatedLine(line, Double(max(1, maxWidth)), .end, ellipsis) ?? line
        ctx.saveGState()
        ctx.translateBy(x: 0, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: box.height - TextFormatter.baseline(size: size, inLineOf: box.height))
        CTLineDraw(cut, ctx)
        ctx.restoreGState()
    }
}
