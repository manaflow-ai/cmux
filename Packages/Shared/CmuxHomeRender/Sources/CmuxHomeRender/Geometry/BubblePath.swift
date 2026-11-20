import CoreGraphics

/// Message bubble outline: a rounded body plus the small hanging tail at the
/// bottom corner on the sender's side.
enum BubblePath {
    /// The tail in outgoing space, relative to the body's (maxX, maxY).
    static func tail() -> CGMutablePath {
        let t = CGMutablePath()
        t.move(to: CGPoint(x: -16, y: -3))
        t.addLine(to: CGPoint(x: -16, y: 0))
        t.addCurve(to: CGPoint(x: -5, y: 5.25), control1: CGPoint(x: -11, y: 1.0), control2: CGPoint(x: -7.5, y: 3.4))
        t.addCurve(to: CGPoint(x: -7.2, y: -3.5), control1: CGPoint(x: -5.4, y: 2.8), control2: CGPoint(x: -6.4, y: 0))
        t.closeSubpath()
        return t
    }

    /// How far the tail hangs below the body (it curls under the corner and
    /// stays inside the body's horizontal span).
    static let tailDrop: CGFloat = 5.25

    static func make(body r: CGRect, outgoing: Bool, tail hasTail: Bool, radius: CGFloat = Style.bubbleRadius) -> CGPath {
        let body = RoundedRect.path(r, radius: min(radius, r.height / 2))
        guard hasTail else { return body }
        var transform = outgoing
            ? CGAffineTransform(translationX: r.maxX, y: r.maxY)
            : CGAffineTransform(translationX: r.minX, y: r.maxY).scaledBy(x: -1, y: 1)
        guard let t = tail().copy(using: &transform) else { return body }
        return body.union(t)
    }
}
