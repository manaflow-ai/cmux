import CoreGraphics

/// The page view's place on screen, as the host's window takes it.
nonisolated struct ChromiumHostGeometry: Equatable, Sendable {
    var width: Int32
    var height: Int32
    /// Bottom left of the view in screen points.
    var screenX: Int32
    var screenY: Int32
    var scaleMilli: Int32

    init(screenRect: CGRect, scale: CGFloat) {
        width = Int32(screenRect.width.rounded())
        height = Int32(screenRect.height.rounded())
        screenX = Int32(screenRect.minX.rounded())
        screenY = Int32(screenRect.minY.rounded())
        scaleMilli = Int32((scale * 1_000).rounded())
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension ChromiumHostGeometry {
    var frame: ChromiumHostFrame {
        ChromiumHostFrame(.geometry, v: [width, height, screenX, screenY, scaleMilli])
    }
}
#endif
