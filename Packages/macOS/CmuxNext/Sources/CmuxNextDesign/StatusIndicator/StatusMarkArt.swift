import AppKit
import CoreText

/// Draws a `StatusMark` as an alpha mask (opaque where the mark is), the one
/// drawing the live indicator layer and the image export both use. Vector
/// paths in unflipped space, sized from the slot so they stay crisp from
/// 10 to 32 points; badges cut their figure out of the container.
@MainActor
enum StatusMarkArt {
    /// The mark in a square of `pixels`, as an alpha-only image.
    static func mask(_ mark: StatusMark, pixels: Int) -> CGImage? {
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels,
                                                  space: CGColorSpaceCreateDeviceGray(),
                                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.setShouldAntialias(true)
        draw(mark, in: context, rect: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
    }

    /// Draws `mark` opaque into `rect` of `context` (the caller tints).
    static func draw(_ mark: StatusMark, in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch mark {
        case .glyph(let figure):
            drawFigure(figure, in: context, box: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06), large: true)
        case .badge(let container, let figure):
            fillContainer(container, in: context, rect: rect)
            if let figure {
                context.setBlendMode(.clear)
                drawFigure(figure, in: context, box: innerBox(container, rect), large: false)
                context.setBlendMode(.normal)
            }
        case .outline(let container, let figure):
            strokeContainer(container, in: context, rect: rect)
            if let figure { drawFigure(figure, in: context, box: innerBox(container, rect), large: false) }
        case .letter(let letter):
            fillContainer(.roundedSquare, in: context, rect: rect)
            context.setBlendMode(.clear)
            drawLetter(letter, in: context, rect: rect)
            context.setBlendMode(.normal)
        case .symbol(let name):
            drawSymbol(name, in: context, rect: rect)
        }
    }

    // MARK: Containers

    private static func containerPath(_ container: StatusMark.Container, _ rect: CGRect) -> CGPath {
        let w = rect.width
        switch container {
        case .circle:
            return CGPath(ellipseIn: rect.insetBy(dx: w * 0.04, dy: w * 0.04), transform: nil)
        case .roundedSquare:
            let r = rect.insetBy(dx: w * 0.06, dy: w * 0.06)
            return CGPath(roundedRect: r, cornerWidth: w * 0.22, cornerHeight: w * 0.22, transform: nil)
        case .triangle:
            let path = CGMutablePath()
            path.addLines(between: [point(rect, 0.5, 0.92), point(rect, 0.06, 0.12), point(rect, 0.94, 0.12)])
            path.closeSubpath()
            return path
        case .octagon:
            let path = CGMutablePath()
            let center = CGPoint(x: rect.midX, y: rect.midY), radius = w * 0.47
            for index in 0..<8 {
                let angle = CGFloat.pi / 8 + CGFloat(index) * .pi / 4
                let p = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        }
    }

    private static func fillContainer(_ container: StatusMark.Container, in context: CGContext, rect: CGRect) {
        let path = containerPath(container, rect)
        context.addPath(path)
        context.fillPath()
        if container == .triangle {
            // Round the triangle's corners: stroke its outline wide.
            context.addPath(path)
            context.setLineWidth(rect.width * 0.1)
            context.strokePath()
        }
    }

    private static func strokeContainer(_ container: StatusMark.Container, in context: CGContext, rect: CGRect) {
        let line = max(1, rect.width * 0.1)
        context.setLineWidth(line)
        context.addPath(containerPath(container, rect.insetBy(dx: line / 2, dy: line / 2)))
        context.strokePath()
    }

    /// The figure's box inside a container.
    private static func innerBox(_ container: StatusMark.Container, _ rect: CGRect) -> CGRect {
        switch container {
        case .circle, .octagon: rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.26)
        case .roundedSquare: rect.insetBy(dx: rect.width * 0.25, dy: rect.height * 0.25)
        case .triangle: CGRect(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.2, width: rect.width * 0.4, height: rect.height * 0.46)
        }
    }

    // MARK: Figures

    static func point(_ box: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
    }

    /// `large` figures fill the slot alone (thinner strokes relative to size).
    private static func drawFigure(_ figure: StatusMark.Figure, in context: CGContext, box: CGRect, large: Bool) {
        let w = min(box.width, box.height)
        let line = max(1, w * (large ? 0.14 : 0.18))
        context.setLineWidth(line)
        func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            let c = point(box, x, y)
            context.fillEllipse(in: CGRect(x: c.x - r * w, y: c.y - r * w, width: 2 * r * w, height: 2 * r * w))
        }
        switch figure {
        case .exclamation:
            context.move(to: point(box, 0.5, 0.92))
            context.addLine(to: point(box, 0.5, 0.42))
            context.setLineWidth(max(1, w * 0.2))
            context.strokePath()
            dot(0.5, 0.1, 0.11)
        case .question:
            let radius = w * 0.24
            let center = point(box, 0.5, 0.7)
            context.addArc(center: center, radius: radius, startAngle: .pi * 0.95, endAngle: -.pi * 0.25, clockwise: true)
            context.addLine(to: point(box, 0.5, 0.36))
            context.setLineWidth(max(1, w * 0.17))
            context.strokePath()
            dot(0.5, 0.1, 0.1)
        case .key:
            let head = point(box, 0.3, 0.5)
            let r = w * 0.2
            context.setLineWidth(max(1, w * 0.14))
            context.strokeEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r))
            context.move(to: point(box, 0.5, 0.5))
            context.addLine(to: point(box, 0.95, 0.5))
            context.move(to: point(box, 0.8, 0.5))
            context.addLine(to: point(box, 0.8, 0.3))
            context.move(to: point(box, 0.93, 0.5))
            context.addLine(to: point(box, 0.93, 0.34))
            context.strokePath()
        case .check:
            context.addPath(StatusGlyphGeometry.checkPath(in: box.insetBy(dx: w * 0.08, dy: w * 0.14)))
            context.strokePath()
        case .cross:
            context.move(to: point(box, 0.18, 0.18))
            context.addLine(to: point(box, 0.82, 0.82))
            context.move(to: point(box, 0.82, 0.18))
            context.addLine(to: point(box, 0.18, 0.82))
            context.strokePath()
        case .hand:
            let palm = CGRect(x: box.minX + w * 0.2, y: box.minY + w * 0.04, width: w * 0.6, height: w * 0.52)
            context.addPath(CGPath(roundedRect: palm, cornerWidth: w * 0.2, cornerHeight: w * 0.2, transform: nil))
            context.fillPath()
            let finger = w * 0.13
            context.setLineWidth(finger)
            for (x, top) in [(0.28, 0.78), (0.42, 0.92), (0.57, 0.9), (0.71, 0.76)] as [(CGFloat, CGFloat)] {
                context.move(to: point(box, x, 0.4))
                context.addLine(to: point(box, x, top))
            }
            context.move(to: point(box, 0.26, 0.24))
            context.addLine(to: point(box, 0.08, 0.5))
            context.strokePath()
        case .shield:
            let path = CGMutablePath()
            path.move(to: point(box, 0.5, 0.96))
            path.addLine(to: point(box, 0.88, 0.82))
            path.addCurve(to: point(box, 0.5, 0.02), control1: point(box, 0.88, 0.4), control2: point(box, 0.72, 0.16))
            path.addCurve(to: point(box, 0.12, 0.82), control1: point(box, 0.28, 0.16), control2: point(box, 0.12, 0.4))
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        case .bubble, .bubbleQuestion:
            let body = CGRect(x: box.minX, y: box.minY + w * 0.22, width: w, height: w * 0.74)
            context.addPath(CGPath(roundedRect: body, cornerWidth: w * 0.26, cornerHeight: w * 0.26, transform: nil))
            context.addLines(between: [point(box, 0.22, 0.3), point(box, 0.14, 0.0), point(box, 0.5, 0.3)])
            context.fillPath()
            if figure == .bubbleQuestion {
                context.setBlendMode(.clear)
                drawFigure(.question, in: context, box: body.insetBy(dx: body.width * 0.28, dy: body.height * 0.16), large: false)
                context.setBlendMode(.normal)
            }
        case .sparkle:
            let path = CGMutablePath()
            let c = point(box, 0.5, 0.5)
            let tips = [point(box, 0.5, 1), point(box, 1, 0.5), point(box, 0.5, 0), point(box, 0, 0.5)]
            path.move(to: tips[0])
            for index in 1...4 {
                let tip = tips[index % 4]
                let previous = tips[index - 1]
                let control = CGPoint(x: c.x + (previous.x + tip.x - 2 * c.x) * 0.12, y: c.y + (previous.y + tip.y - 2 * c.y) * 0.12)
                path.addQuadCurve(to: tip, control: control)
            }
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        case .dot:
            dot(0.5, 0.5, 0.26)
        case .pip:
            dot(0.5, 0.5, 0.17)
        case .hollowPip:
            let r = w * 0.17
            let c = point(box, 0.5, 0.5)
            context.setLineWidth(max(1, w * 0.09))
            context.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .diamond:
            let s: CGFloat = 0.2
            context.addLines(between: [point(box, 0.5, 0.5 + s), point(box, 0.5 + s, 0.5), point(box, 0.5, 0.5 - s), point(box, 0.5 - s, 0.5)])
            context.closePath()
            context.fillPath()
        }
    }

    // MARK: Text and symbols

    private static func drawLetter(_ letter: String, in context: CGContext, rect: CGRect) {
        let font = NSFont.systemFont(ofSize: rect.height * 0.62, weight: .heavy)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.black]))
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX, y: rect.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    private static func drawSymbol(_ name: String, in context: CGContext, rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.8, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let fit = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // The template's alpha is the mark.
        context.draw(cg, in: target)
    }
}
