#if os(iOS)
import CoreGraphics
import SwiftUI

/// An iMessage-style message bubble with its tail at a bottom corner.
///
/// The outline is the measured iOS 26 ChatKit balloon geometry. Keeping the
/// curve here (rather than approximating it with rounded rectangles) makes
/// quoted and sent Feed messages share the same corners and tucked tail as
/// Messages. The shape's frame includes the tail drop; callers reserve that
/// space with ``tailReserve`` so the tail does not overlap the next row.
struct AgentFeedBubbleShape: Shape {
    /// ChatKit tucks the iOS 26 tail inside the bubble's horizontal bounds.
    static let tailWidth: CGFloat = 0

    /// Space reserved below the body for the tail. The actual path scales the
    /// drop with its effective corner radius, while this reserve keeps the
    /// usual footnote-sized Feed bubbles inside their layout frame.
    static let tailReserve: CGFloat = 6

    private static let referenceRadius: CGFloat = 20.1435546875
    private static let referenceTailDrop: CGFloat = 6.8337

    var tailEdge: HorizontalEdge = .leading
    var cornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        // The layout frame includes a small tail reserve. Solve the body
        // height once or twice so the scaled ChatKit tail ends at the frame's
        // bottom edge even when Dynamic Type changes the corner radius.
        var bodyHeight = max(0, rect.height - Self.tailReserve)
        for _ in 0..<3 {
            let radius = min(cornerRadius, bodyHeight / 2, rect.width / 2)
            let drop = Self.referenceTailDrop * max(0, radius) / Self.referenceRadius
            bodyHeight = max(0, rect.height - drop)
        }

        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight)
        let side: AgentFeedBubbleGeometry.Side = tailEdge == .leading ? .leading : .trailing
        let cgPath = AgentFeedBubbleGeometry.path(
            in: body,
            side: side,
            tail: true,
            radius: cornerRadius,
            tailWidth: Self.tailWidth,
            tailDrop: Self.referenceTailDrop * max(0, cornerRadius) / Self.referenceRadius
        )
        return Path(cgPath)
    }
}

/// The continuous corners and tucked tail used by CKBalloonShapeLayer on
/// iOS 26. Coordinates are top-left-origin, matching SwiftUI's Path space.
private extension AgentFeedBubbleShape {
    struct AgentFeedBubbleGeometry {
    enum Side {
        case leading
        case trailing
    }

    static func path(
        in rect: CGRect,
        side: Side,
        tail: Bool,
        radius: CGFloat,
        tailWidth: CGFloat,
        tailDrop: CGFloat
    ) -> CGPath {
        var body = rect
        body.size.width -= tailWidth
        if side == .leading { body.origin.x += tailWidth }
        // `tailDrop` is part of the public call shape for documentation and
        // future variants; the measured offsets below carry the drop itself.
        _ = tailDrop
        return iOSPath(in: body, side: side, tail: tail, radius: radius)
    }

    private struct CornerAxis {
        var a: [CGFloat]

        init(halfExtent: CGFloat, radius r: CGFloat) {
            let pill: [CGFloat] = [1, 0.87327, 0.74768, 0.62993, 0.37476, 0.17266, 0.07099, 0.02408]
            let normal: [CGFloat] = [1.52866, 1.08849, 0.86841, 0.63152, 0.37282, 0.16905, 0.07491, 0]
            let t = r > 0 ? max(0, min(1, (halfExtent - r) / (0.52866 * r))) : 1
            a = zip(pill, normal).map { ($0 + ($1 - $0) * t) * r }
        }
    }

    private static func cornerPoints(vertical v: CornerAxis, horizontal h: CornerAxis) -> [CGPoint] {
        [
            CGPoint(x: 0, y: v.a[0]),
            CGPoint(x: 0, y: v.a[1]), CGPoint(x: v.a[7], y: v.a[2]), CGPoint(x: v.a[6], y: v.a[3]),
            CGPoint(x: v.a[5], y: v.a[4]), CGPoint(x: h.a[4], y: h.a[5]), CGPoint(x: h.a[3], y: h.a[6]),
            CGPoint(x: h.a[2], y: h.a[7]), CGPoint(x: h.a[1], y: 0), CGPoint(x: h.a[0], y: 0),
        ]
    }

    /// Offsets from the bottom-trailing corner at the reference radius.
    private static let iOSTail: [CGPoint] = [
        CGPoint(x: 0, y: -15.806), CGPoint(x: -1.425, y: -11.584), CGPoint(x: -4.057, y: -8.134),
        CGPoint(x: -5.123, y: -6.736), CGPoint(x: -6.355, y: -5.503), CGPoint(x: -7.715, y: -4.455),
        CGPoint(x: -9.654, y: -2.943), CGPoint(x: -10.493, y: -1.366), CGPoint(x: -10.493, y: 0.407),
        CGPoint(x: -10.493, y: 1.598), CGPoint(x: -10.282, y: 2.775), CGPoint(x: -8.571, y: 5.023),
        CGPoint(x: -7.750, y: 6.101), CGPoint(x: -8.574, y: 7.201), CGPoint(x: -9.857, y: 6.714),
        CGPoint(x: -12.496, y: 5.711), CGPoint(x: -15.502, y: 3.887), CGPoint(x: -18.134, y: 1.941),
        CGPoint(x: -20.493, y: 0.196), CGPoint(x: -21.122, y: 0.020), CGPoint(x: -22.228, y: 0.013),
    ]

    private static func iOSPath(in rect: CGRect, side: Side, tail: Bool, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.height / 2, rect.width / 2))
        let local = iOSTrailingTailPath(width: rect.width, height: rect.height, radius: r, tail: tail)
        var transform = side == .leading
            ? CGAffineTransform(translationX: rect.maxX, y: rect.minY).scaledBy(x: -1, y: 1)
            : CGAffineTransform(translationX: rect.minX, y: rect.minY)
        return local.copy(using: &transform) ?? local
    }

    private static func iOSTrailingTailPath(width w: CGFloat, height h: CGFloat, radius r: CGFloat, tail: Bool) -> CGPath {
        let vertical = CornerAxis(halfExtent: h / 2, radius: r)
        let horizontal = CornerAxis(halfExtent: w / 2, radius: r)
        let corner = cornerPoints(vertical: vertical, horizontal: horizontal)
        let path = CGMutablePath()

        func addCorner(_ map: (CGPoint) -> CGPoint, reversed: Bool) {
            let points = reversed ? Array(corner.reversed()) : corner
            path.addLine(to: map(points[0]))
            for index in stride(from: 1, to: points.count, by: 3) {
                path.addCurve(
                    to: map(points[index + 2]),
                    control1: map(points[index]),
                    control2: map(points[index + 1])
                )
            }
        }

        path.move(to: CGPoint(x: horizontal.a[0], y: 0))
        addCorner({ CGPoint(x: w - $0.x, y: $0.y) }, reversed: true)
        if tail {
            let scale = r / 20.1435546875
            path.addLine(to: CGPoint(x: w, y: h - vertical.a[0]))
            for index in stride(from: 0, to: iOSTail.count, by: 3) {
                func point(_ offset: CGPoint) -> CGPoint {
                    CGPoint(x: w + offset.x * scale, y: h + offset.y * scale)
                }
                path.addCurve(
                    to: point(iOSTail[index + 2]),
                    control1: point(iOSTail[index]),
                    control2: point(iOSTail[index + 1])
                )
            }
        } else {
            addCorner({ CGPoint(x: w - $0.x, y: h - $0.y) }, reversed: false)
        }
        addCorner({ CGPoint(x: $0.x, y: h - $0.y) }, reversed: true)
        addCorner({ $0 }, reversed: false)
        path.closeSubpath()
        return path
    }
    }
}
#endif
