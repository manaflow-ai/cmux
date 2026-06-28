public import CoreGraphics

/// Pure geometry kernels shared by the AppKit terminal surface witnesses.
///
/// These are the epsilon-comparison and backing-scale derivations that were
/// duplicated inside `GhosttyNSView` and `GhosttySurfaceScrollView`. They hold
/// no state and touch no AppKit object, so they live here as static `Sendable`
/// helpers; the witnesses keep their private/static one-line forwarders and
/// read live `window`/`layer` scale app-side before calling in.
public enum TerminalSurfaceGeometry {
    /// Whether two scalars are within `epsilon` of each other.
    public static func approxEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        epsilon: CGFloat
    ) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    /// Whether two sizes are within `epsilon` on both axes.
    public static func approxEqual(
        _ lhs: CGSize,
        _ rhs: CGSize,
        epsilon: CGFloat
    ) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon && abs(lhs.height - rhs.height) <= epsilon
    }

    /// Whether two points are within `epsilon` on both axes.
    public static func approxEqual(
        _ lhs: CGPoint,
        _ rhs: CGPoint,
        epsilon: CGFloat
    ) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    /// Whether two rects are within `epsilon` on origin and size.
    public static func approxEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        epsilon: CGFloat
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    /// The backing-pixel size for a point size at `scale`.
    ///
    /// Mirrors the surface-size derivation: the caller passes the window
    /// backing scale (falling back to the layer's `contentsScale`, then `1`),
    /// so ancestor magnification (canvas zoom) never re-typesets the grid. The
    /// scale is clamped to at least `1` before multiplying.
    public static func pixelSize(for pointsSize: CGSize, scale: CGFloat) -> CGSize {
        let clamped = max(1.0, scale)
        return CGSize(width: pointsSize.width * clamped, height: pointsSize.height * clamped)
    }
}
