import CoreGraphics

/// The Chrome group rail's top-end cut, in the sidebar's flipped y-down coordinates.
/// The left edge stays straight; the right edge flares into the header before tapering to the rail.
enum SidebarGroupLineShape {
    /// A visible, one-sided taper: `height` is the rail body height, while the path's
    /// `flareHeight` points sit above it and `flareWidth` is independent of the 2 pt rail.
    static func topTaper(railWidth: CGFloat, flareWidth: CGFloat, flareHeight: CGFloat, height: CGFloat) -> CGPath {
        let railWidth = max(0, railWidth)
        let flareWidth = max(railWidth, flareWidth)
        let flareHeight = max(0, flareHeight)
        let height = max(0, height)
        let totalHeight = flareHeight + height
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: flareWidth, y: 0))
        if flareHeight > 0 {
            // The control points keep the left edge square and make the right edge a
            // concave, right-only flare rather than a symmetric rounded cap.
            path.addCurve(to: CGPoint(x: railWidth, y: flareHeight),
                          control1: CGPoint(x: flareWidth, y: flareHeight * 0.2),
                          control2: CGPoint(x: railWidth + (flareWidth - railWidth) * 0.15, y: flareHeight * 0.85))
        }
        path.addLine(to: CGPoint(x: railWidth, y: totalHeight))
        path.addLine(to: CGPoint(x: 0, y: totalHeight))
        path.closeSubpath()
        return path
    }
}
