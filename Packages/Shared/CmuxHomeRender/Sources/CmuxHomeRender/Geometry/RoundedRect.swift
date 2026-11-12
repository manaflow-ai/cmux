import CoreGraphics

/// Rounded rectangles that match `UIBezierPath(roundedRect:cornerRadius:)`
/// point for point (measured against UIKit on the same rects):
/// - both sides >= 2 * 1.52866 r: continuous corners of radius r;
/// - one short side: capsule ends whose curves scale with half the short side;
/// - both sides short: circular caps of radius min(r, short / 2).
enum RoundedRect {
    static let k: CGFloat = 1.52866483

    static func path(_ r: CGRect, radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        add(p, r, radius: radius)
        return p
    }

    static func add(_ p: CGMutablePath, _ rect: CGRect, radius: CGFloat) {
        guard radius > 0, rect.width > 0, rect.height > 0 else { p.addRect(rect); return }
        let need = 2 * k * radius
        if rect.width >= need && rect.height >= need {
            continuous(p, rect, radius)
        } else if rect.width >= need || rect.height >= need {
            if rect.width >= rect.height { shortSide(p, rect, radius) }
            else {
                // Vertical capsule: build it transposed, then swap x and y back.
                let t = CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
                let q = CGMutablePath()
                shortSide(q, t, radius)
                var swap = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
                if let c = q.copy(using: &swap) { p.addPath(c) }
            }
        } else {
            let c = min(radius, min(rect.width, rect.height) / 2)
            p.addRoundedRect(in: rect, cornerWidth: c, cornerHeight: c)
        }
    }

    /// Continuous corners (Apple's 3-curve corner, 1.52866 r along each edge).
    private static func continuous(_ p: CGMutablePath, _ rect: CGRect, _ r: CGFloat) {
        func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.minY + y * r) }
        func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.maxY - y * r) }
        func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.maxY - y * r) }
        func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.minY + y * r) }
        func corner(_ f: (CGFloat, CGFloat) -> CGPoint, swap: Bool) {
            func q(_ a: CGFloat, _ b: CGFloat) -> CGPoint { swap ? f(b, a) : f(a, b) }
            p.addCurve(to: q(0.63149399, 0.07491176), control1: q(1.08849323, 0), control2: q(0.86840689, 0))
            p.addCurve(to: q(0.07491176, 0.63149399), control1: q(0.37282392, 0.16906013), control2: q(0.16906013, 0.37282392))
            p.addCurve(to: q(0, k), control1: q(0, 0.86840689), control2: q(0, 1.08849323))
        }
        p.move(to: tl(k, 0))
        p.addLine(to: tr(k, 0)); corner(tr, swap: false)
        p.addLine(to: br(0, k)); corner(br, swap: true)
        p.addLine(to: bl(k, 0)); corner(bl, swap: false)
        p.addLine(to: tl(0, k)); corner(tl, swap: true)
        p.closeSubpath()
    }

    /// Wide rect with a short height: each end is two curves scaled by
    /// s = height / 2 (corners entered from an edge start at 1.52866 r,
    /// corners left into an edge end at 1.509915 s, as UIKit draws them).
    private static func shortSide(_ p: CGMutablePath, _ rect: CGRect, _ r: CGFloat) {
        let s = rect.height / 2
        let (a, b, c, d, e) = (1.069743 as CGFloat, 0.849657 as CGFloat, 0.612743 as CGFloat, 0.074911 as CGFloat, 1.509915 as CGFloat)
        let (f, g, h) = (0.244858 as CGFloat, 0.208811 as CGFloat, 0.558504 as CGFloat)
        let L = rect.minX, R = rect.maxX, T = rect.minY, B = rect.maxY
        p.move(to: CGPoint(x: L + k * r, y: T))
        p.addLine(to: CGPoint(x: R - k * r, y: T))
        // Top right (entered from the top edge).
        p.addCurve(to: CGPoint(x: R - c * s, y: T + d * s), control1: CGPoint(x: R - a * s, y: T), control2: CGPoint(x: R - b * s, y: T))
        p.addCurve(to: CGPoint(x: R, y: T + 0.95 * s), control1: CGPoint(x: R - f * s, y: T + g * s), control2: CGPoint(x: R, y: T + h * s))
        p.addLine(to: CGPoint(x: R, y: B - 0.95 * s))
        // Bottom right (left into the bottom edge).
        p.addCurve(to: CGPoint(x: R - c * s, y: B - d * s), control1: CGPoint(x: R, y: B - h * s), control2: CGPoint(x: R - f * s, y: B - g * s))
        p.addCurve(to: CGPoint(x: R - e * s, y: B), control1: CGPoint(x: R - b * s, y: B), control2: CGPoint(x: R - a * s, y: B))
        p.addLine(to: CGPoint(x: L + k * r, y: B))
        // Bottom left (entered from the bottom edge).
        p.addCurve(to: CGPoint(x: L + c * s, y: B - d * s), control1: CGPoint(x: L + a * s, y: B), control2: CGPoint(x: L + b * s, y: B))
        p.addCurve(to: CGPoint(x: L, y: B - 0.95 * s), control1: CGPoint(x: L + f * s, y: B - g * s), control2: CGPoint(x: L, y: B - h * s))
        p.addLine(to: CGPoint(x: L, y: T + 0.95 * s))
        // Top left (left into the top edge).
        p.addCurve(to: CGPoint(x: L + c * s, y: T + d * s), control1: CGPoint(x: L, y: T + h * s), control2: CGPoint(x: L + f * s, y: T + g * s))
        p.addCurve(to: CGPoint(x: L + e * s, y: T), control1: CGPoint(x: L + b * s, y: T), control2: CGPoint(x: L + a * s, y: T))
        p.closeSubpath()
    }
}
