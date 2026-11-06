public import CoreGraphics

/// The one rule every nested rounded shape of the pane chrome follows (Lawrence 2026-11-04:
/// "all nested radius everywhere ... must be concentric, where inner radius is outer minus
/// padding, where padding is configurable too").
///
/// A rounded shape set `padding` points inside a rounded shape of radius `outer` reads as part of
/// it only when the two curves share a center: its radius is `outer - padding`, never negative.
/// A shape drawn `padding` points outside (a ring around a card) is `outer + padding`. Each level
/// of nesting applies the rule again, so a shape `depth` levels in is `outer - depth * padding`.
///
/// The pane chrome reads one value of this type (`Metrics.corners`): `outer` is the corner radius
/// setting (`layout.paneCornerRadius`, shared by panes, the curved main pane and tab bar tabs) and
/// `padding` the corner padding setting (`layout.cornerPadding`, the gap between a pane's edge
/// and its tab pills). Views never write a radius literal; they ask this type.
///
/// ```swift
/// let corners = ConcentricCorners(outer: 10, padding: 2)
/// corners.inner                         // 8: a tab pill in a 10 pt card
/// corners.nested(in: 8, inset: 3)       // 5: a close button 3 pt inside that pill
/// corners.radius(fitting: CGSize(width: 40, height: 6), radius: 8) // 3: half the short side
/// ```
public nonisolated struct ConcentricCorners: Hashable, Sendable {
    /// The outermost rounded shape's radius in points, never negative.
    public var outer: CGFloat
    /// The gap in points between a rounded shape and the one nested in it, never negative.
    public var padding: CGFloat

    /// - Parameter outer: The outer radius; a negative value is 0 (square).
    /// - Parameter padding: The gap to the next shape in; a negative value is 0.
    public init(outer: CGFloat, padding: CGFloat) {
        self.outer = max(0, outer)
        self.padding = max(0, padding)
    }

    /// The radius one level in: `outer - padding`, at least 0.
    public var inner: CGFloat { radius(depth: 1) }

    /// The radius `depth` levels in (`outer - depth * padding`, at least 0); depth 0 is ``outer``,
    /// a negative depth is outside the outer shape.
    public func radius(depth: Int) -> CGFloat {
        max(0, outer - CGFloat(depth) * padding)
    }

    /// The radius of a shape `inset` points inside a shape of radius `radius`: `radius - inset`,
    /// at least 0. A negative inset is a shape outside it (`radius + |inset|`).
    public func nested(in radius: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, radius - inset)
    }

    /// `radius`, at most half the shorter side of `size`, so the corners never overlap.
    public func radius(fitting size: CGSize, radius: CGFloat) -> CGFloat {
        max(0, min(radius, min(size.width, size.height) / 2))
    }
}
