import CoreGraphics

/// Paths the indicator layer and the image export share, so an exported
/// status image (`StatusIconSet.image`) has the live glyph's geometry. All
/// in unflipped (bottom-left) space.
nonisolated enum StatusGlyphGeometry {
    /// A ring that starts at 12 o'clock and runs clockwise, so `strokeEnd`
    /// reads as progress.
    static func ringPath(in rect: CGRect, thickness: CGFloat) -> CGPath {
        let radius = max(0, min(rect.width, rect.height) / 2 - thickness / 2)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        return path
    }

    static func checkPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }

    /// The check's box inside the glyph square.
    static func checkRect(in rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.2)
    }

    /// The still dot (waiting, error, busy dot) at `scale` of the square.
    static func dotRect(in rect: CGRect, scale: CGFloat) -> CGRect {
        let side = rect.width * scale
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// Dot diameter as a share of the glyph square: three dots and two gaps
    /// of half a dot fill the width (3 + 2 * 0.5 = 4 dots wide).
    static let dotsDiameterShare: CGFloat = 0.25

    /// The working dots or bars: one element's frame in the square's own
    /// coordinates, and the step between copies.
    static func repeatedElement(in size: CGSize, bars: Bool) -> (frame: CGRect, step: CGFloat) {
        if bars {
            let width = size.width * 0.18
            let step = width * 1.7
            let height = size.height * 0.7
            let total = width * 3 + (step - width) * 2
            return (CGRect(x: (size.width - total) / 2, y: (size.height - height) / 2, width: width, height: height), step)
        }
        let side = size.width * dotsDiameterShare
        return (CGRect(x: 0, y: (size.height - side) / 2, width: side, height: side), side * 1.5)
    }

    /// The path of one working element in its own frame.
    static func repeatedElementPath(_ frame: CGRect, bars: Bool) -> CGPath {
        let bounds = CGRect(origin: .zero, size: frame.size)
        guard bars else { return CGPath(ellipseIn: bounds, transform: nil) }
        let radius = bounds.width / 2
        return CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
