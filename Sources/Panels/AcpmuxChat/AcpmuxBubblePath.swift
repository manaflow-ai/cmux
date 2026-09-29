import CoreGraphics

/// Builds iMessage-style bubble outlines in a flipped (top-left origin) coordinate space.
///
/// The tail is part of one continuous outline: the side edge flares out into the tip and
/// the curve returns along the bottom edge, so a single fill covers bubble and tail with
/// no seam, overlap, or winding hole.
struct AcpmuxBubblePath {
    enum TailSide {
        case leading
        case trailing
    }

    let radius: CGFloat

    /// How far the tail tip extends past the bubble's side edge.
    static let tailReach: CGFloat = 5

    func path(for rect: CGRect, tail: TailSide?) -> CGPath {
        let r = min(radius, rect.height / 2, rect.width / 2)
        guard let tail else {
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        // Build the trailing shape, then mirror it for a leading tail.
        let path = CGMutablePath()
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let reach = Self.tailReach
        path.move(to: CGPoint(x: minX + r, y: minY))
        path.addLine(to: CGPoint(x: maxX - r, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r), radius: r)
        // The right edge runs down, then bends outward into the tip at the bottom corner.
        path.addLine(to: CGPoint(x: maxX, y: max(minY + r, maxY - r)))
        path.addCurve(
            to: CGPoint(x: maxX + reach, y: maxY),
            control1: CGPoint(x: maxX, y: maxY - r * 0.35),
            control2: CGPoint(x: maxX + reach * 0.4, y: maxY - 1)
        )
        // From the tip the underside sweeps back into the bottom edge.
        path.addCurve(
            to: CGPoint(x: maxX - r * 0.9, y: maxY - 1.5),
            control1: CGPoint(x: maxX - 2, y: maxY + 0.5),
            control2: CGPoint(x: maxX - r * 0.5, y: maxY - 0.5)
        )
        path.addQuadCurve(to: CGPoint(x: maxX - r * 1.3, y: maxY), control: CGPoint(x: maxX - r * 1.1, y: maxY))
        path.addLine(to: CGPoint(x: minX + r, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r), radius: r)
        path.addLine(to: CGPoint(x: minX, y: minY + r))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY), radius: r)
        path.closeSubpath()
        guard tail == .leading else { return path }
        var mirror = CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &mirror) ?? path
    }
}
