import CoreGraphics

/// The members' line's outlines, in y-down coordinates (the sidebar's rows and lines are flipped).
/// Measured on Leo's Chrome reference at 2x (2026-10-19): a line's left corners are square and its
/// right corners are cut by a quarter circle as wide as the line.
enum SidebarGroupLineShape {
    /// The line alone, in a `width` by `height` box.
    static func line(width w: CGFloat, height h: CGFloat) -> CGPath {
        let r = min(w, h / 2)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addArc(center: CGPoint(x: 0, y: r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        path.addLine(to: CGPoint(x: r, y: h - r))
        path.addArc(center: CGPoint(x: 0, y: h - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        path.closeSubpath()
        return path
    }

    /// A header bar and its members' line as one outline (`sidebar.groupLineJoinsHeader`): the bar
    /// (`width` by `barHeight`, corners `radius`) with its bottom-left corner square, and from it the
    /// line, `lineWidth` wide at the bar's own left edge, `length` below the bar, its end trimmed as
    /// `line`'s.
    static func joined(width: CGFloat, barHeight b: CGFloat, radius: CGFloat, lineWidth w: CGFloat, length: CGFloat) -> CGPath {
        let r = min(radius, b / 2, width / 2), t = min(w, length)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: width - r, y: 0))
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: r), radius: r)
        path.addLine(to: CGPoint(x: width, y: b - r))
        path.addArc(tangent1End: CGPoint(x: width, y: b), tangent2End: CGPoint(x: width - r, y: b), radius: r)
        path.addLine(to: CGPoint(x: w, y: b))
        path.addLine(to: CGPoint(x: w, y: b + length - t))
        path.addArc(center: CGPoint(x: w - t, y: b + length - t), radius: t, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: b + length))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: r, y: 0), radius: r)
        path.closeSubpath()
        return path
    }
}
