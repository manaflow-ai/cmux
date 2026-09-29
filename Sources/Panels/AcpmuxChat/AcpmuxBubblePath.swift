import CoreGraphics

/// Builds Messages-style bubble outlines in a flipped (top-left origin) coordinate space.
///
/// The tail is part of one continuous outline: the side edge curls out into the tip and
/// the curve returns along the bottom edge, so one fill covers bubble and tail with no
/// seam, overlap, or winding hole. Bubbles inside a group get a small radius on the
/// corners that face their neighbors, as Messages does.
struct AcpmuxBubblePath {
    enum Side {
        case leading
        case trailing
    }

    /// The outer corner radius.
    let radius: CGFloat
    /// The radius of corners that face another bubble in the same group.
    let groupedRadius: CGFloat

    /// How far the tail tip extends past the bubble's side edge.
    static let tailReach: CGFloat = 6

    init(radius: CGFloat = 17.5, groupedRadius: CGFloat = 5) {
        self.radius = radius
        self.groupedRadius = groupedRadius
    }

    /// The outline for a bubble on `side`.
    /// - Parameters:
    ///   - rect: The bubble body; the tail extends ``tailReach`` beyond it.
    ///   - side: Which side the speaker is on. Tail and grouped corners sit on this side.
    ///   - tail: Whether this is the last bubble of its group.
    ///   - groupedAbove: Whether a bubble from the same speaker sits directly above.
    ///   - groupedBelow: Whether a bubble from the same speaker sits directly below.
    func path(for rect: CGRect, side: Side, tail: Bool, groupedAbove: Bool, groupedBelow: Bool) -> CGPath {
        let limit = min(rect.height / 2, rect.width / 2)
        let outer = min(radius, limit)
        let sideTop = groupedAbove ? min(groupedRadius, limit) : outer
        let sideBottom = tail ? outer : (groupedBelow ? min(groupedRadius, limit) : outer)
        // Build for the trailing side, then mirror for leading.
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX + outer, y: minY))
        path.addLine(to: CGPoint(x: maxX - sideTop, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + sideTop), radius: sideTop)
        if tail {
            let reach = Self.tailReach
            // The side edge runs straight to the tail's root, then curls out to the tip.
            path.addLine(to: CGPoint(x: maxX, y: max(minY + sideTop, maxY - outer)))
            path.addCurve(
                to: CGPoint(x: maxX + reach, y: maxY),
                control1: CGPoint(x: maxX, y: maxY - outer * 0.3),
                control2: CGPoint(x: maxX + reach * 0.35, y: maxY - 0.5)
            )
            // The underside sweeps back from the tip and joins the bottom edge tangentially.
            path.addCurve(
                to: CGPoint(x: maxX - outer * 0.75, y: maxY - 1.2),
                control1: CGPoint(x: maxX - 1.5, y: maxY + 0.6),
                control2: CGPoint(x: maxX - outer * 0.4, y: maxY - 0.2)
            )
            path.addQuadCurve(to: CGPoint(x: maxX - outer * 1.25, y: maxY), control: CGPoint(x: maxX - outer, y: maxY))
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY - sideBottom))
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - sideBottom, y: maxY), radius: sideBottom)
        }
        path.addLine(to: CGPoint(x: minX + outer, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - outer), radius: outer)
        path.addLine(to: CGPoint(x: minX, y: minY + outer))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + outer, y: minY), radius: outer)
        path.closeSubpath()
        guard side == .leading else { return path }
        var mirror = CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &mirror) ?? path
    }

    /// A plain rounded rectangle, for cards.
    static func card(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
