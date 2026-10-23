import CoreGraphics

/// The Chrome group rail's top-end cut, in the sidebar's flipped y-down coordinates.
/// The left edge stays square on the header rail; only the right edge tapers out of the top end.
enum SidebarGroupLineShape {
    static func topTaper(width: CGFloat, height: CGFloat, radius: CGFloat) -> CGPath {
        let r = min(width, height, max(0, radius))
        let path = CGMutablePath()
        path.move(to: .zero)
        if r > 0 {
            path.addArc(center: CGPoint(x: 0, y: r), radius: r,
                        startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        }
        path.addLine(to: CGPoint(x: r, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}
