import CoreGraphics

/// The outline that UIKit's `UIBezierPath(roundedRect:cornerRadius:)` builds
/// (continuous corners), element for element. Reverse engineered from UIKit's
/// output on Mac Catalyst (tools/diff-harness/rounded-rect-check.sh checks it
/// against UIKit on a random grid). Core Graphics' own rounded rect and
/// SwiftUI's continuous rectangle differ from it when a side is shorter than
/// 2 x 1.528665 r (every one-line bubble), so the AppKit port builds the
/// same path itself.
///
/// Four regimes, by which half-extents are shorter than k r (k = 1.528665):
/// - neither: the continuous corner, scaled by r;
/// - the height only: a pill-like corner scaled by h / 2 (the straight
///   top and bottom edges still end k r from the corners);
/// - the width only: the same, transposed;
/// - both: circular arcs of radius min(w, h) / 2.
/// UIKit's path is open (no close element) and contains zero-length and
/// degenerate segments; they are kept, so boolean operations on the path
/// (`CGPath.union`) see the same input.
enum UIKitRoundedRect {
    static let k = 1.528665
    // The continuous corner, in units of r, measured along the incoming edge
    // (u) and the outgoing edge (v) from the corner.
    static let a1 = 1.088492957618529, a2 = 0.868406944063002, a3 = 0.631493792830992, b3 = 0.074911387847016
    static let m1u = 0.372823826625747, m1v = 0.169059556044370
    static let kc = 1.528664984729582
    // The limited (pill) corner, in units of the limited half-extent s.
    static let shift = 0.018750150000000
    static let p1u = 0.244857803399491, p1v = 0.208810883008118, p2v = 0.558504066868353
    static let kappa = 0.5522847498

    static func path(_ rect: CGRect, radius r: CGFloat) -> CGMutablePath {
        let p = CGMutablePath()
        let x0 = Double(rect.minX), y0 = Double(rect.minY)
        let w = Double(rect.width), h = Double(rect.height)
        let r = Double(r)
        let hw = w / 2, hh = h / 2
        let limH = hh < k * r, limW = hw < k * r
        // Local corner frames: a point (u, v) of a corner maps to window space.
        func tr(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: x0 + w - u, y: y0 + v) }
        func br(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: x0 + w - v, y: y0 + h - u) }
        func bl(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: x0 + u, y: y0 + h - v) }
        func tl(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: x0 + v, y: y0 + u) }
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x0 + x, y: y0 + y) }
        func c(_ a: CGPoint, _ b: CGPoint, _ e: CGPoint) { p.addCurve(to: e, control1: a, control2: b) }
        func l(_ a: CGPoint) { p.addLine(to: a) }

        if !limH && !limW {
            p.move(to: pt(k * r, 0))
            for f in [tr, br, bl, tl] {
                l(f(k * r, 0))
                c(f(a1 * r, 0), f(a2 * r, 0), f(a3 * r, b3 * r))
                l(f(a3 * r, b3 * r))
                c(f(m1u * r, m1v * r), f(m1v * r, m1u * r), f(b3 * r, a3 * r))
                c(f(0, a2 * r), f(0, a1 * r), f(0, kc * r))
            }
            l(pt(k * r, 0))
            return p
        }
        if limH && limW {
            let q = min(hw, hh), kq = kappa * q
            p.move(to: pt(hw, 0))
            l(pt(hw, 0)); c(pt(w - q, 0), pt(w - q, 0), pt(w - q, 0)); l(pt(w - q, 0))
            c(pt(w - q + kq, 0), pt(w, q - kq), pt(w, q)); c(pt(w, q), pt(w, q), pt(w, q)); l(pt(w, hh))
            c(pt(w, h - q), pt(w, h - q), pt(w, h - q)); l(pt(w, h - q))
            c(pt(w, h - q + kq), pt(w - q + kq, h), pt(w - q, h)); c(pt(w - q, h), pt(w - q, h), pt(w - q, h)); l(pt(hw, h))
            c(pt(q, h), pt(q, h), pt(q, h)); l(pt(q, h))
            c(pt(q - kq, h), pt(0, h - q + kq), pt(0, h - q)); c(pt(0, h - q), pt(0, h - q), pt(0, h - q)); l(pt(0, hh))
            c(pt(0, q), pt(0, q), pt(0, q)); l(pt(0, q))
            c(pt(0, q - kq), pt(q - kq, 0), pt(q, 0)); c(pt(q, 0), pt(q, 0), pt(q, 0)); l(pt(hw, 0))
            return p
        }
        let s = limH ? hh : hw
        let (b1, b2, b3s, end) = ((a1 - shift) * s, (a2 - shift) * s, (a3 - shift) * s, (kc - shift) * s)
        if limH {
            p.move(to: pt(k * r, 0))
            // Top right: from the top edge into the pill end of the right side.
            l(tr(k * r, 0)); c(tr(b1, 0), tr(b2, 0), tr(b3s, b3 * s)); l(tr(b3s, b3 * s))
            c(tr(p1u * s, p1v * s), pt(w, p2v * s), pt(w, 0.95 * s)); c(pt(w, s), pt(w, s), pt(w, s)); l(pt(w, s))
            // Bottom right.
            c(pt(w, s), pt(w, s), pt(w, s)); l(pt(w, h - 0.95 * s))
            c(pt(w, h - p2v * s), pt(w - p1u * s, h - p1v * s), pt(w - b3s, h - b3 * s))
            c(pt(w - b2, h), pt(w - b1, h), pt(w - end, h))
            // Bottom left.
            l(pt(k * r, h)); c(pt(b1, h), pt(b2, h), pt(b3s, h - b3 * s)); l(pt(b3s, h - b3 * s))
            c(pt(p1u * s, h - p1v * s), pt(0, h - p2v * s), pt(0, h - 0.95 * s)); c(pt(0, s), pt(0, s), pt(0, s)); l(pt(0, s))
            // Top left.
            c(pt(0, s), pt(0, s), pt(0, s)); l(pt(0, 0.95 * s))
            c(pt(0, p2v * s), pt(p1u * s, p1v * s), pt(b3s, b3 * s))
            c(pt(b2, 0), pt(b1, 0), pt(end, 0))
            l(pt(k * r, 0))
            return p
        }
        // Width limited: the transpose.
        p.move(to: pt(s, 0))
        l(pt(s, 0)); c(pt(s, 0), pt(s, 0), pt(s, 0)); l(pt(w - 0.95 * s, 0))
        c(pt(w - p2v * s, 0), pt(w - p1v * s, p1u * s), pt(w - b3 * s, b3s))
        c(pt(w, b2), pt(w, b1), pt(w, end))
        l(pt(w, h - k * r)); c(pt(w, h - b1), pt(w, h - b2), pt(w - b3 * s, h - b3s)); l(pt(w - b3 * s, h - b3s))
        c(pt(w - p1v * s, h - p1u * s), pt(w - p2v * s, h), pt(w - 0.95 * s, h)); c(pt(s, h), pt(s, h), pt(s, h)); l(pt(s, h))
        c(pt(s, h), pt(s, h), pt(s, h)); l(pt(0.95 * s, h))
        c(pt(p2v * s, h), pt(p1v * s, h - p1u * s), pt(b3 * s, h - b3s))
        c(pt(0, h - b2), pt(0, h - b1), pt(0, h - end))
        l(pt(0, k * r)); c(pt(0, b1), pt(0, b2), pt(b3 * s, b3s)); l(pt(b3 * s, b3s))
        c(pt(p1v * s, p1u * s), pt(p2v * s, 0), pt(0.95 * s, 0)); c(pt(s, 0), pt(s, 0), pt(s, 0)); l(pt(s, 0))
        return p
    }

    /// UIKit's oval: four quarter curves from the right-middle point, closed.
    static func oval(_ r: CGRect) -> CGMutablePath {
        let p = CGMutablePath()
        let cx = Double(r.midX), cy = Double(r.midY), rx = Double(r.width) / 2, ry = Double(r.height) / 2
        let kx = kappa * rx, ky = kappa * ry
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        p.move(to: pt(cx + rx, cy))
        p.addCurve(to: pt(cx, cy + ry), control1: pt(cx + rx, cy + ky), control2: pt(cx + kx, cy + ry))
        p.addCurve(to: pt(cx - rx, cy), control1: pt(cx - kx, cy + ry), control2: pt(cx - rx, cy + ky))
        p.addCurve(to: pt(cx, cy - ry), control1: pt(cx - rx, cy - ky), control2: pt(cx - kx, cy - ry))
        p.addCurve(to: pt(cx + rx, cy), control1: pt(cx + kx, cy - ry), control2: pt(cx + rx, cy - ky))
        p.closeSubpath()
        return p
    }
}
