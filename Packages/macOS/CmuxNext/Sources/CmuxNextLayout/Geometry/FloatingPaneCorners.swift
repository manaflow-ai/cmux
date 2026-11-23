import CmuxNextDesign
public import CoreGraphics

/// The corner radii of a floating pane's card. Each corner follows the window's corner by the concentric rule
/// (`ConcentricCorners`): its radius is the window's radius less the corner's distance from the window's edges,
/// and never below a floor. A card near a corner of the window is rounder there; a card away from the edges has the
/// floor at each corner.
///
/// ```swift
/// // A card 4 pt from the left and top edges of a window with a 16 pt corner:
/// let corners = FloatingPaneCorners(size: CGSize(width: 300, height: 200), left: 4, top: 4, right: 500, bottom: 300,
///                                   windowRadius: 16, floor: 6)
/// corners.topLeft      // 12: the window's 16 less the 4 pt gap
/// corners.bottomRight  // 6: the floor
/// ```
public nonisolated struct FloatingPaneCorners: Equatable, Sendable {
    public var topLeft: CGFloat
    public var topRight: CGFloat
    public var bottomLeft: CGFloat
    public var bottomRight: CGFloat

    /// The same radius at each corner.
    public init(uniform radius: CGFloat) {
        (topLeft, topRight, bottomLeft, bottomRight) = (radius, radius, radius, radius)
    }

    /// - Parameters:
    ///   - size: The card's size; no radius is over half its shorter side.
    ///   - left: The distance of the card's left edge from the window's left edge; `top`, `right` and `bottom`
    ///     likewise. A negative distance (a card past the edge) is 0.
    ///   - windowRadius: The radius of the window's own corners; 0 for a window with square corners (full screen).
    ///   - floor: The smallest radius.
    public init(size: CGSize, left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat, windowRadius: CGFloat, floor: CGFloat) {
        let rule = ConcentricCorners(outer: windowRadius, padding: 0)
        // A corner is concentric with the window's when both of its edges are the same distance in; with two
        // distances the larger one gives the radius, so the curve never goes outside the window's curve.
        func corner(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            rule.radius(fitting: size, radius: max(floor, rule.nested(in: rule.outer, inset: max(0, a, b))))
        }
        topLeft = corner(left, top)
        topRight = corner(right, top)
        bottomLeft = corner(left, bottom)
        bottomRight = corner(right, bottom)
    }

    /// The largest of the 4 radii.
    public var largest: CGFloat { max(topLeft, topRight, bottomLeft, bottomRight) }

    /// The one radius of the content `inset` points inside the card: the largest corner's, by the concentric rule,
    /// so no corner of the content goes outside the card's curve.
    public func contentRadius(inset: CGFloat) -> CGFloat { max(0, largest - inset) }

    /// The outline in `rect`, `inset` points in (each radius is less by `inset`), in a space whose y goes down
    /// (`rect.minY` is the top).
    public func path(in rect: CGRect, inset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath(), box = rect.insetBy(dx: inset, dy: inset)
        guard box.width > 0, box.height > 0 else { return path }
        let limit = min(box.width, box.height) / 2
        func radius(_ value: CGFloat) -> CGFloat { min(max(0, value - inset), limit) }
        let (tl, tr, bl, br) = (radius(topLeft), radius(topRight), radius(bottomLeft), radius(bottomRight))
        path.move(to: CGPoint(x: box.minX + tl, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - tr, y: box.minY))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - br))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX - br, y: box.maxY), radius: br)
        path.addLine(to: CGPoint(x: box.minX + bl, y: box.maxY))
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + tl))
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX + tl, y: box.minY), radius: tl)
        path.closeSubpath()
        return path
    }
}
