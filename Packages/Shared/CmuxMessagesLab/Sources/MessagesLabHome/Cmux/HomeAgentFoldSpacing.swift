#if DEBUG
import AppKit
import CoreGraphics
import CoreText

/// DEBUG ONLY: the shipped agent-message line (chevron, muted label, gray chips) with other spacing, for the
/// Agent Messages Playground's spacing variants (user 2026-11-02, msg 19733: "i want to see more variations
/// of this ui still the spacing, i am not a fan of"). Each value is in points; the shipped line is
/// ``shipped`` (22 tall, no padding, at the bubbles' left edge, 6 pt gaps, 16 pt chips with 6 pt padding).
struct HomeAgentFoldSpacing: Equatable, Sendable {
    /// Room above the line (more gap to the bubble above) and below it (to the bubble below).
    var above: CGFloat = 0, below: CGFloat = 0
    /// The line's own height (the chevron, label and chips are centered in it).
    var line: CGFloat = 22
    /// From the bubbles' left edge to the chevron.
    var indent: CGFloat = 0
    /// Chevron box width and the gap after it; the gap between the label and the first chip.
    var chevron: CGFloat = 10, chevronGap: CGFloat = 6, labelGap: CGFloat = 6
    /// Chip height, its text's side padding and the gap between chips; `chips` false: the agents as text.
    var chipHeight: CGFloat = 16, chipPad: CGFloat = 6, chipGap: CGFloat = 4, chips = true
    /// Label and chip type sizes.
    var labelSize: CGFloat = 12, chipSize: CGFloat = 11

    static let shipped = HomeAgentFoldSpacing()

    /// The row's height: the padding and the line.
    var height: CGFloat { above + line + below }

    /// Draws an agents row (`p`) with this spacing, or an opened note's line, in `rect`.
    func draw(_ p: HomeAgentFoldRowProvider.Payload, in ctx: CGContext, rect: CGRect) {
        let muted = Fixture.secondaryText
        let mid = rect.minY + above + line / 2
        var x = rect.minX + indent
        if p.chevron { stroke(ctx, chevronAt: CGPoint(x: x + chevron / 2, y: mid), open: p.open, color: muted) }
        x += chevron + chevronGap
        let labelFont = HomeFonts.system(ofSize: labelSize, weight: p.role == "note" ? .regular : .medium)
        x += text(ctx, NSAttributedString(string: p.label, attributes: [.font: labelFont, .foregroundColor: muted]), x: x, mid: mid)
        guard !p.chips.isEmpty else { return }
        let chipFont = HomeFonts.system(ofSize: chipSize, weight: .regular)
        func ink(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: chipFont, .foregroundColor: muted]) }
        guard chips else {
            let names = ink(" · " + p.chips.joined(separator: ", "))
            truncate(ctx, names, x: x, mid: mid, width: rect.maxX - x - 8)
            return
        }
        x += labelGap
        for (index, chip) in p.chips.enumerated() {
            let name = ink(chip)
            let w = HomeTableGrid.lineWidth(name) + 2 * chipPad
            guard x + w + (index < p.chips.count - 1 ? 30 : 0) <= rect.maxX - 8 else {
                _ = text(ctx, ink("+\(p.chips.count - index)"), x: x + 2, mid: mid)
                return
            }
            let pill = CGRect(x: x, y: mid - chipHeight / 2, width: w, height: chipHeight)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: chipHeight / 2, cornerHeight: chipHeight / 2, transform: nil))
            ctx.setFillColor(muted.withAlphaComponent(0.14).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            _ = text(ctx, name, x: x + chipPad, mid: mid)
            x += w + chipGap
        }
    }
}

// MARK: Drawing helpers (pure CoreGraphics and CoreText, any thread)

private func text(_ ctx: CGContext, _ s: NSAttributedString, x: CGFloat, mid: CGFloat) -> CGFloat {
    draw(ctx, CTLineCreateWithAttributedString(s), x: x, mid: mid)
}

private func truncate(_ ctx: CGContext, _ s: NSAttributedString, x: CGFloat, mid: CGFloat, width: CGFloat) {
    guard width > 12, s.length > 0 else { return }
    let full = CTLineCreateWithAttributedString(s)
    let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: s.attributes(at: 0, effectiveRange: nil)))
    _ = draw(ctx, CTLineCreateTruncatedLine(full, Double(width), .end, token) ?? full, x: x, mid: mid)
}

private func draw(_ ctx: CGContext, _ ctLine: CTLine, x: CGFloat, mid: CGFloat) -> CGFloat {
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: mid + (ascent - descent) / 2)
    CTLineDraw(ctLine, ctx)
    ctx.restoreGState()
    return width.rounded(.up)
}

private func stroke(_ ctx: CGContext, chevronAt c: CGPoint, open: Bool, color: NSColor) {
    ctx.saveGState()
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(1.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    if open {
        ctx.move(to: CGPoint(x: c.x - 3.5, y: c.y - 1.75))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + 1.75))
        ctx.addLine(to: CGPoint(x: c.x + 3.5, y: c.y - 1.75))
    } else {
        ctx.move(to: CGPoint(x: c.x - 1.75, y: c.y - 3.5))
        ctx.addLine(to: CGPoint(x: c.x + 1.75, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x - 1.75, y: c.y + 3.5))
    }
    ctx.strokePath()
    ctx.restoreGState()
}
#endif
