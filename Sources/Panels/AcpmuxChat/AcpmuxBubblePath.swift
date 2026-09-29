import CoreGraphics

/// Builds iMessage-style bubble outlines in a flipped (top-left origin) coordinate space.
struct AcpmuxBubblePath {
    enum TailSide {
        case leading
        case trailing
    }

    let radius: CGFloat

    func path(for rect: CGRect, tail: TailSide?) -> CGPath {
        let path = CGMutablePath()
        let clamped = min(radius, rect.height / 2, rect.width / 2)
        path.addRoundedRect(in: rect, cornerWidth: clamped, cornerHeight: clamped)
        guard let tail else { return path }
        switch tail {
        case .trailing:
            path.move(to: CGPoint(x: rect.maxX - 8, y: rect.maxY - 14))
            path.addQuadCurve(to: CGPoint(x: rect.maxX + 5, y: rect.maxY), control: CGPoint(x: rect.maxX - 3, y: rect.maxY - 1))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 16, y: rect.maxY - 1), control: CGPoint(x: rect.maxX - 6, y: rect.maxY + 1))
            path.closeSubpath()
        case .leading:
            path.move(to: CGPoint(x: rect.minX + 8, y: rect.maxY - 14))
            path.addQuadCurve(to: CGPoint(x: rect.minX - 5, y: rect.maxY), control: CGPoint(x: rect.minX + 3, y: rect.maxY - 1))
            path.addQuadCurve(to: CGPoint(x: rect.minX + 16, y: rect.maxY - 1), control: CGPoint(x: rect.minX + 6, y: rect.maxY + 1))
            path.closeSubpath()
        }
        return path
    }
}
