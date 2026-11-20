import AppKit
import CoreGraphics
import CoreText
import Foundation

/// One caption line laid out for a width: chevron, label, then as many chips as fit and "+N" for
/// the rest. Pure CoreText and CoreGraphics, any thread (row bitmaps draw off main).
struct HomeAgentFoldLine {
    let open: Bool
    let chevron: Bool
    let label: NSAttributedString
    let chips: [NSAttributedString]
    /// Chips that did not fit ("+3"), nil when all fit.
    let more: NSAttributedString?

    init(_ payload: HomeAgentFoldRowProvider.Payload, width: CGFloat) {
        let color = Fixture.secondaryText
        open = payload.open
        chevron = payload.chevron
        label = NSAttributedString(string: payload.label, attributes: [.font: HomeFonts.system(ofSize: 12, weight: .medium), .foregroundColor: color])
        let chipFont = HomeFonts.system(ofSize: 11, weight: .regular)
        let all = payload.chips.map { NSAttributedString(string: $0, attributes: [.font: chipFont, .foregroundColor: color]) }
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

    func draw(_ ctx: CGContext, at origin: CGPoint) {
        typealias P = HomeAgentFoldRowProvider
        let mid = origin.y + P.height / 2
        let color = Fixture.secondaryText
        // The chevron: right while folded, down while open; none on a note's line (it sits under the label).
        if chevron { drawChevron(ctx, center: CGPoint(x: origin.x + P.chevronWidth / 2, y: mid)) }
        var x = origin.x + P.chevronWidth + P.gap
        x += Self.drawText(ctx, label, x: x, mid: mid) + P.gap
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

    /// The chevron centered on `c`, in the caption's muted color: right while folded, down while open.
    private func drawChevron(_ ctx: CGContext, center c: CGPoint) {
        ctx.saveGState()
        ctx.setStrokeColor(Fixture.secondaryText.cgColor)
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
