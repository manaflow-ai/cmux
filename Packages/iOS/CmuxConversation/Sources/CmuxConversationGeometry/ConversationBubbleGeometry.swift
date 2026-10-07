import CoreGraphics

/// The Messages bubble outline, shared by the iOS and macOS surfaces. Paths
/// use top-left-origin coordinates (UIKit, or a flipped AppKit view).
public enum ConversationBubbleGeometry {
    public enum Side: Sendable {
        case leading
        case trailing
    }

    /// macOS Messages is Mac Catalyst ChatKit and draws the same outline as
    /// iOS (CKBalloonShapeLayer on macOS 26.7), scaled by its corner radius;
    /// both styles render it.
    public enum TailStyle: Sendable {
        case iOS
        case macOS
    }

    /// `rect` includes the tail area on `side` whether or not a tail is drawn,
    /// so tailed and tailless bubbles in a run share one body edge. A tailed
    /// bubble also draws `iOSTailDrop(radius:)` below `rect`; `tailDrop` is
    /// kept for callers and must match it.
    public static func path(
        in rect: CGRect,
        side: Side,
        tail: Bool,
        radius: CGFloat,
        tailWidth: CGFloat,
        tailDrop: CGFloat,
        style: TailStyle = .iOS
    ) -> CGPath {
        var body = rect
        body.size.width -= tailWidth
        if side == .leading { body.origin.x += tailWidth }
        return iOSPath(in: body, side: side, tail: tail, radius: radius)
    }

    // MARK: iOS 26 outline

    /// Corner radius ChatKit's tail coordinates were measured at (17 pt body text).
    static let iOSReferenceRadius: CGFloat = 20.1435546875

    /// How far an iOS tail drops below the body for a bubble with corner `radius`.
    public static func iOSTailDrop(radius: CGFloat) -> CGFloat {
        6.8337 * radius / iOSReferenceRadius
    }

    /// The iOS 26 Messages outline for a body of `rect`: ChatKit's continuous
    /// corners (`radius` is half a single-line bubble's height) and, when
    /// `tail` is set, the tail tucked inside the body's bottom corner on
    /// `side`, dropping `iOSTailDrop(radius:)` below `rect`.
    public static func iOSPath(in rect: CGRect, side: Side, tail: Bool, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.height / 2, rect.width / 2))
        let local = iOSTrailingTailPath(width: rect.width, height: rect.height, radius: r, tail: tail)
        var transform = side == .leading
            ? CGAffineTransform(translationX: rect.maxX, y: rect.minY).scaledBy(x: -1, y: 1)
            : CGAffineTransform(translationX: rect.minX, y: rect.minY)
        return local.copy(using: &transform) ?? local
    }

    /// Distances along one axis of a ChatKit continuous corner, in units of
    /// the radius. A side long enough for the full corner (1.52866 r per
    /// half) uses the `normal` values; a pill-length side (r per half) uses
    /// `pill`; ChatKit interpolates linearly between them.
    private struct CornerAxis {
        var a: [CGFloat]
        init(halfExtent: CGFloat, radius r: CGFloat) {
            let pill: [CGFloat] = [1, 0.87327, 0.74768, 0.62993, 0.37476, 0.17266, 0.07099, 0.02408]
            let normal: [CGFloat] = [1.52866, 1.08849, 0.86841, 0.63152, 0.37282, 0.16905, 0.07491, 0]
            let t = r > 0 ? max(0, min(1, (halfExtent - r) / (0.52866 * r))) : 1
            a = zip(pill, normal).map { ($0 + ($1 - $0) * t) * r }
        }
    }

    /// One corner as (u, v) points, u measured from the vertical edge and v
    /// from the horizontal edge, running from the vertical side to the
    /// horizontal side: start, then three curves of (c1, c2, end).
    private static func cornerPoints(vertical v: CornerAxis, horizontal h: CornerAxis) -> [CGPoint] {
        [
            CGPoint(x: 0, y: v.a[0]),
            CGPoint(x: 0, y: v.a[1]), CGPoint(x: v.a[7], y: v.a[2]), CGPoint(x: v.a[6], y: v.a[3]),
            CGPoint(x: v.a[5], y: v.a[4]), CGPoint(x: h.a[4], y: h.a[5]), CGPoint(x: h.a[3], y: h.a[6]),
            CGPoint(x: h.a[2], y: h.a[7]), CGPoint(x: h.a[1], y: 0), CGPoint(x: h.a[0], y: 0),
        ]
    }

    /// The iOS tail, as offsets from the body's bottom-trailing corner at
    /// the reference radius: three-point curves from the trailing side
    /// (at `h - Ly`) down to the tip and back into the bottom edge.
    private static let iOSTail: [CGPoint] = [
        CGPoint(x: 0, y: -15.806), CGPoint(x: -1.425, y: -11.584), CGPoint(x: -4.057, y: -8.134),
        CGPoint(x: -5.123, y: -6.736), CGPoint(x: -6.355, y: -5.503), CGPoint(x: -7.715, y: -4.455),
        CGPoint(x: -9.654, y: -2.943), CGPoint(x: -10.493, y: -1.366), CGPoint(x: -10.493, y: 0.407),
        CGPoint(x: -10.493, y: 1.598), CGPoint(x: -10.282, y: 2.775), CGPoint(x: -8.571, y: 5.023),
        CGPoint(x: -7.750, y: 6.101), CGPoint(x: -8.574, y: 7.201), CGPoint(x: -9.857, y: 6.714),
        CGPoint(x: -12.496, y: 5.711), CGPoint(x: -15.502, y: 3.887), CGPoint(x: -18.134, y: 1.941),
        CGPoint(x: -20.493, y: 0.196), CGPoint(x: -21.122, y: 0.020), CGPoint(x: -22.228, y: 0.013),
    ]

    /// Body spans x in [0, width] and y in [0, height], drawn clockwise in
    /// top-left-origin coordinates. With `tail`, the bottom-trailing corner
    /// is replaced by the tail, which stays inside the body's width.
    private static func iOSTrailingTailPath(width w: CGFloat, height h: CGFloat, radius r: CGFloat, tail: Bool = true) -> CGPath {
        let vertical = CornerAxis(halfExtent: h / 2, radius: r)
        let horizontal = CornerAxis(halfExtent: w / 2, radius: r)
        let corner = cornerPoints(vertical: vertical, horizontal: horizontal)
        let p = CGMutablePath()
        func addCorner(_ map: (CGPoint) -> CGPoint, reversed: Bool) {
            let points = reversed ? Array(corner.reversed()) : corner
            p.addLine(to: map(points[0]))
            for i in stride(from: 1, to: points.count, by: 3) {
                p.addCurve(to: map(points[i + 2]), control1: map(points[i]), control2: map(points[i + 1]))
            }
        }
        p.move(to: CGPoint(x: horizontal.a[0], y: 0))
        addCorner({ CGPoint(x: w - $0.x, y: $0.y) }, reversed: true)
        if tail {
            let s = r / iOSReferenceRadius
            p.addLine(to: CGPoint(x: w, y: h - vertical.a[0]))
            for i in stride(from: 0, to: iOSTail.count, by: 3) {
                func at(_ o: CGPoint) -> CGPoint { CGPoint(x: w + o.x * s, y: h + o.y * s) }
                p.addCurve(to: at(iOSTail[i + 2]), control1: at(iOSTail[i]), control2: at(iOSTail[i + 1]))
            }
        } else {
            addCorner({ CGPoint(x: w - $0.x, y: h - $0.y) }, reversed: false)
        }
        addCorner({ CGPoint(x: $0.x, y: h - $0.y) }, reversed: true)
        addCorner({ $0 }, reversed: false)
        p.closeSubpath()
        return p
    }
}
