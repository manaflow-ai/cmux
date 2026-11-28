import CoreGraphics
import CoreText

/// Drawing of the attachment parts that are pixels of their own: the file
/// chip's document icon and text, and the play badge over a video.
/// Nonisolated: chips draw off the main actor inside `RowBitmaps`.
enum AttachmentDrawing {
    /// A folded document icon with the type badge, then the name and
    /// "<kind> · <size>" (the chip body's coordinates are `body`).
    static func drawChip(_ ctx: CGContext, _ file: FilePart, in body: CGRect, outgoing: Bool, palette: HomePalette) {
        let fg = (outgoing ? palette.outgoingText : palette.incomingText).cgColor
        let icon = FileChip.icon.offsetBy(dx: body.minX, dy: body.minY)
        let fold: CGFloat = 8
        let doc = CGMutablePath()
        doc.move(to: CGPoint(x: icon.minX + 3, y: icon.minY))
        doc.addLine(to: CGPoint(x: icon.maxX - fold, y: icon.minY))
        doc.addLine(to: CGPoint(x: icon.maxX, y: icon.minY + fold))
        doc.addLine(to: CGPoint(x: icon.maxX, y: icon.maxY - 3))
        doc.addQuadCurve(to: CGPoint(x: icon.maxX - 3, y: icon.maxY), control: CGPoint(x: icon.maxX, y: icon.maxY))
        doc.addLine(to: CGPoint(x: icon.minX + 3, y: icon.maxY))
        doc.addQuadCurve(to: CGPoint(x: icon.minX, y: icon.maxY - 3), control: CGPoint(x: icon.minX, y: icon.maxY))
        doc.addLine(to: CGPoint(x: icon.minX, y: icon.minY + 3))
        doc.addQuadCurve(to: CGPoint(x: icon.minX + 3, y: icon.minY), control: CGPoint(x: icon.minX, y: icon.minY))
        doc.closeSubpath()
        Canvas.fill(ctx, doc, fg.copy(alpha: 0.92) ?? fg)
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: icon.maxX - fold, y: icon.minY))
        corner.addLine(to: CGPoint(x: icon.maxX - fold, y: icon.minY + fold))
        corner.addLine(to: CGPoint(x: icon.maxX, y: icon.minY + fold))
        corner.closeSubpath()
        Canvas.fill(ctx, corner, fg.copy(alpha: 0.55) ?? fg)
        let ink = (outgoing ? palette.outgoing(at: 1) : palette.incomingBubble).cgColor
        if !file.badge.isEmpty {
            let w = TextDraw.width(file.badge, font: FileChip.badgeFont)
            TextDraw.line(file.badge, font: FileChip.badgeFont, color: ink, x: icon.midX - w / 2, baseline: icon.maxY - 6, in: ctx)
        }
        for i in 0..<3 {
            let line = CGRect(x: icon.minX + 6, y: icon.minY + 11 + CGFloat(i) * 4, width: i == 2 ? 10 : 16, height: 1.5)
            ctx.setFillColor(ink.copy(alpha: 0.45) ?? ink)
            ctx.fill(line)
        }
        let x = body.minX + FileChip.textLeft
        TextDraw.line(file.name, font: FileChip.nameFont, color: fg, x: x, baseline: body.minY + FileChip.nameBaseline, in: ctx)
        TextDraw.line(file.detail, font: FileChip.detailFont, color: fg.copy(alpha: 0.7) ?? fg, x: x,
                      baseline: body.minY + FileChip.detailBaseline, in: ctx)
    }

    /// The play badge: a translucent dark disc with a light triangle.
    static let playDiameter: CGFloat = 40

    static func playBadge(scale: CGFloat) -> CGImage? {
        let d = playDiameter
        return Canvas.image(size: CGSize(width: d, height: d), scale: scale) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
            let c = CGPoint(x: d / 2 + 2, y: d / 2)
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: c.x - 6, y: c.y - 9))
            tri.addLine(to: CGPoint(x: c.x + 9, y: c.y))
            tri.addLine(to: CGPoint(x: c.x - 6, y: c.y + 9))
            tri.closeSubpath()
            Canvas.fill(ctx, tri, CGColor(gray: 1, alpha: 0.92))
        }
    }
}
