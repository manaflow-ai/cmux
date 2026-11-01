import AppKit
import CoreGraphics
import CoreText
import Foundation

/// One caption line laid out for a width: chevron, label, then as many chips as fit and "+N" for
/// the rest. Pure CoreText and CoreGraphics, any thread (row bitmaps draw off main).
struct HomeAgentFoldLine {
    let open: Bool
    let style: Int
    let label: NSAttributedString
    let chips: [NSAttributedString]
    /// Chips that did not fit ("+3"), nil when all fit.
    let more: NSAttributedString?

    init(_ payload: HomeAgentFoldRowProvider.Payload, width: CGFloat) {
        let color = Fixture.secondaryText
        open = payload.open
        style = payload.style
        let labelText = payload.style == 2 ? "" : payload.label
        let labelFont = payload.style == 5 ? HomeFonts.system(ofSize: 12, weight: .bold) : HomeFonts.system(ofSize: payload.style == 3 || payload.style == 4 ? 11 : 12, weight: .medium)
        let labelColor = payload.style == 8 ? NSColor.controlAccentColor : color
        label = NSAttributedString(string: labelText, attributes: [.font: labelFont, .foregroundColor: labelColor])
        let chipFont = HomeFonts.system(ofSize: 11, weight: .regular)
        let all = (payload.style == 5 ? [] : payload.chips).map { NSAttributedString(string: $0, attributes: [.font: chipFont, .foregroundColor: color]) }
        typealias P = HomeAgentFoldRowProvider
        var x = P.chevronWidth + P.gap + HomeTableGrid.lineWidth(label) + P.gap
        var fitting: [NSAttributedString] = []
        for (index, chip) in all.enumerated() {
            let w = HomeTableGrid.lineWidth(chip) + 2 * P.chipPadX
            // Keep room for a "+N" after the last chip that fits.
            let reserve: CGFloat = index < all.count - 1 ? 30 : 0
            guard x + w + reserve <= width else { break }
            fitting.append(chip)
            x += w + P.chipGap
        }
        chips = fitting
        let rest = all.count - fitting.count
        more = rest > 0 ? NSAttributedString(string: "+\(rest)", attributes: [.font: chipFont, .foregroundColor: color]) : nil
    }

    /// The line's natural width (chevron, label, chips, "+N").
    var contentWidth: CGFloat {
        typealias P = HomeAgentFoldRowProvider
        var w = P.chevronWidth + P.gap + HomeTableGrid.lineWidth(label) + P.gap
        for chip in chips { w += HomeTableGrid.lineWidth(chip) + 2 * P.chipPadX + P.chipGap }
        if let more { w += HomeTableGrid.lineWidth(more) + 2 }
        return w
    }

    /// SCRATCH: draws the line in its style across `width` (centered styles 3 and 4, indented 7).
    func draw(_ ctx: CGContext, at origin: CGPoint, width: CGFloat) {
        switch style {
        case 3, 4:
            let w = contentWidth
            let start = CGPoint(x: origin.x + max(0, (width - w) / 2), y: origin.y)
            if style == 4 {
                let mid = origin.y + HomeAgentFoldRowProvider.height / 2
                HomeCardDraw.hairline(ctx, from: CGPoint(x: origin.x, y: mid), to: CGPoint(x: start.x - 8, y: mid), strong: false)
                HomeCardDraw.hairline(ctx, from: CGPoint(x: start.x + w + 8, y: mid), to: CGPoint(x: origin.x + width, y: mid), strong: false)
            }
            draw(ctx, at: start)
        case 7: draw(ctx, at: CGPoint(x: origin.x + Fixture.bubblePadX, y: origin.y))
        default: draw(ctx, at: origin)
        }
    }

    func draw(_ ctx: CGContext, at origin: CGPoint) {
        typealias P = HomeAgentFoldRowProvider
        let mid = origin.y + P.height / 2
        let color = Fixture.secondaryText
        // The chevron: right while folded, down while open.
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let c = CGPoint(x: style == 6 ? origin.x + contentWidth - P.chevronWidth / 2 : origin.x + P.chevronWidth / 2, y: mid)
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
        var x = origin.x + P.chevronWidth + P.gap
        if style == 6 { x = origin.x }
        if label.length > 0 { x += Self.drawText(ctx, label, x: x, mid: mid) + P.gap }
        for chip in chips {
            let w = HomeTableGrid.lineWidth(chip) + 2 * P.chipPadX
            let pill = CGRect(x: x, y: mid - P.chipHeight / 2, width: w, height: P.chipHeight)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: P.chipHeight / 2, cornerHeight: P.chipHeight / 2, transform: nil))
            ctx.setFillColor(color.withAlphaComponent(0.14).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            _ = Self.drawText(ctx, chip, x: x + P.chipPadX, mid: mid)
            x += w + P.chipGap
        }
        if let more { _ = Self.drawText(ctx, more, x: x + 2, mid: mid) }
    }

    /// Draws `text` on one line, vertically centered on `mid` (y down); its width.
    private static func drawText(_ ctx: CGContext, _ text: NSAttributedString, x: CGFloat, mid: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: mid + (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return width.rounded(.up)
    }
}
