import CoreGraphics

/// The Chrome group rail, in the sidebar's flipped y-down coordinates.
/// Both ends round only on the right; the left edge stays one straight line.
enum SidebarGroupLineShape {
    /// A connected rail's clipped shoulder; its containing layer rounds the visible terminal cap.
    /// Keeping the body taller than the view lets that cap follow the bounds spring while shrinking.
    static func connected(width: CGFloat, height: CGFloat) -> CGPath {
        let width = max(0, width), height = max(0, height)
        let notch = min(width / 2, height)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: width - notch, y: 0))
        path.addLine(to: CGPoint(x: width, y: notch))
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }

    /// A flat rail with a quarter-circle radius equal to its full width at both right corners.
    static func line(width: CGFloat, height: CGFloat) -> CGPath {
        let width = max(0, width)
        let height = max(0, height)
        let radius = min(width, height / 2)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        if radius > 0 {
            path.addArc(center: CGPoint(x: width - radius, y: radius), radius: radius,
                        startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            path.addLine(to: CGPoint(x: width, y: height - radius))
            path.addArc(center: CGPoint(x: width - radius, y: height - radius), radius: radius,
                        startAngle: 0, endAngle: .pi / 2, clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: width, y: height))
        }
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}
