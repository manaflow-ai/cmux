#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Message bubble outline: a rounded body plus the small hanging tail.
enum BubblePath {
    /// Bubble outlines by size (cells reuse them for the gradient mask).
    private static var cache: [Key: CGPath] = [:]
    private struct Key: Hashable { var w: CGFloat; var h: CGFloat; var outgoing: Bool; var tail: Bool }
    /// The bubble outline at the origin (main thread).
    static func cached(size: CGSize, outgoing: Bool, tail: Bool) -> CGPath {
        let k = Key(w: size.width, h: size.height, outgoing: outgoing, tail: tail)
        if let p = cache[k] { return p }
        if cache.count > 2000 { cache.removeAll() }
        let p = make(body: CGRect(origin: .zero, size: size), outgoing: outgoing, tail: tail).cgPath
        cache[k] = p
        return p
    }
    static func make(body r: CGRect, outgoing: Bool, tail: Bool, radius: CGFloat = Fixture.bubbleRadius) -> UIBezierPath {
        let rad = min(radius, r.height / 2)
        let path = UIBezierPath(roundedRect: r, cornerRadius: rad)
        guard tail else { return path }
        let t = tailPath(outgoing: outgoing)
        var xf = CGAffineTransform(translationX: r.maxX, y: r.maxY)
        if !outgoing {
            xf = CGAffineTransform(translationX: r.minX, y: r.maxY).scaledBy(x: -1, y: 1)
        }
        t.apply(xf)
        return UIBezierPath(cgPath: path.cgPath.union(t.cgPath))
    }
}

extension BubblePath {
    /// The tail in "outgoing" space, relative to the body's (maxX, maxY): the
    /// caller mirrors it for an incoming bubble. Fitted to real Messages
    /// (the lossless screenshots references/real-messages/state-*.png, 2x;
    /// not the HEVC 4:2:0 recording stills, whose chroma smears edges): the
    /// 0.5-coverage outline of the tail is 0.2-0.4 px from Messages' outline
    /// on average at 2x (was about 1.0 px, 3.2 px at most). Messages' two tails differ slightly, so each side
    /// has its own points. appkit-native/README.md: Bubble outline fit.
    static func tailPath(outgoing: Bool) -> UIBezierPath {
        let t = UIBezierPath()
        if outgoing {
            t.move(to: CGPoint(x: -16, y: -3))
            t.addLine(to: CGPoint(x: -14.909, y: 0))
            t.addCurve(to: CGPoint(x: -5.942, y: 5.142), controlPoint1: CGPoint(x: -13.915, y: 0.8), controlPoint2: CGPoint(x: -9.658, y: 3.984))
            t.addCurve(to: CGPoint(x: -7.085, y: -2.522), controlPoint1: CGPoint(x: -6.505, y: 2.563), controlPoint2: CGPoint(x: -8.857, y: 0))
        } else {
            t.move(to: CGPoint(x: -16, y: -3))
            t.addLine(to: CGPoint(x: -15.637, y: 0))
            t.addCurve(to: CGPoint(x: -5.989, y: 5.335), controlPoint1: CGPoint(x: -14.071, y: 0.761), controlPoint2: CGPoint(x: -9.985, y: 4.248))
            t.addCurve(to: CGPoint(x: -6.359, y: -2.519), controlPoint1: CGPoint(x: -6.582, y: 2.299), controlPoint2: CGPoint(x: -9.02, y: 0))
        }
        t.close()
        return t
    }
}

/// Draws lines of text at explicit baselines with Core Text.
enum TextDraw {
    static func line(_ s: String, font: UIFont, color: UIColor, x: CGFloat, baseline: CGFloat,
                     in ctx: CGContext, underline: String? = nil, link: String? = nil, kern: CGFloat = 0) {
        let attr = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        if let u = underline, let range = s.range(of: u) {
            attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(range, in: s))
        }
        if let l = link, let range = s.range(of: l) {
            attr.addAttributes([.foregroundColor: UIColor(red: 0.27, green: 0.55, blue: 1, alpha: 1),
                                .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(range, in: s))
        }
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func width(_ s: String, font: UIFont, kern: CGFloat = 0) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .kern: kern])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
    }
}

extension CGFloat {
    /// Snap to the 2x device pixel grid.
    var px: CGFloat { (self * 2).rounded() / 2 }
}

/// The Liquid Glass controls (compose field, round buttons, name pill) as
/// measured: flat fill, a bright rim fading inward at top and bottom, and a
/// thin dark edge on the sides.
enum Glass {
    /// Highlight profile of a glass rim: (distance from the edge in pt, white
    /// alpha), top and bottom. Measured on luma in still reference frames.
    struct Rim {
        var top: [(CGFloat, CGFloat)]
        var bottom: [(CGFloat, CGFloat)]
        /// The compose field: a bright outer device pixel (row values over the
        /// fill: +54, +28 at the top) and a soft gradient 7-8 pt in.
        static let field = Rim(top: [(0, 0.365), (0.5, 0.223), (1, 0.06), (1.5, 0.048), (3, 0.024), (5, 0.012), (7, 0)],
                               bottom: [(0, 0.324), (0.5, 0.203), (1, 0.053), (1.5, 0.034), (3, 0.02), (6, 0.01), (8, 0)])
        /// The title pill: a 1 pt
        /// band of two near-equal device pixels (+21..25, +27..32 over the
        /// fill), the inner one brighter, then almost nothing.
        static let small = Rim(top: [(0, 0.10), (0.25, 0.12), (0.5, 0.155), (0.75, 0.15), (1, 0.035), (1.5, 0.015), (3, 0.005), (4, 0)],
                               bottom: [(0, 0.095), (0.25, 0.115), (0.5, 0.15), (0.75, 0.145), (1, 0.035), (1.5, 0.015), (3, 0.005), (4, 0)])
        /// Round buttons (plus, emoji, video): the pills' 1 pt band (outer row
        /// +21..25, inner +27..32 over the fill) over the field's soft inner
        /// gradient (rows 2-7 pt in: +6, +3, +1).
        static let button = Rim(top: [(0, 0.15), (0.25, 0.21), (0.5, 0.17), (0.75, 0.17), (1, 0.06), (1.5, 0.048), (3, 0.024), (5, 0.012), (7, 0)],
                                bottom: [(0, 0.13), (0.25, 0.18), (0.5, 0.17), (0.75, 0.17), (1, 0.053), (1.5, 0.034), (3, 0.02), (6, 0.01), (8, 0)])
        /// The profile before these measurements (callers that pass none).
        static let legacy = Rim(top: [(0, 0.27), (0.5, 0.165), (1, 0.06), (1.5, 0.048), (3, 0.024), (5, 0.012), (7, 0)],
                                bottom: [(0, 0.24), (0.5, 0.15), (1, 0.053), (1.5, 0.034), (3, 0.02), (6, 0.01), (8, 0)])
    }
    static func draw(_ ctx: CGContext, rect: CGRect, radius: CGFloat, fill: CGFloat, rim: Rim = .legacy) {
        let shape = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        UIColor(white: fill / 255, alpha: 1).setFill()
        shape.fill()
        drawRim(ctx, rect: rect, radius: radius, rim: rim)
    }
    /// Top and bottom highlights and the dark side edges, without the fill.
    static func drawRim(_ ctx: CGContext, rect: CGRect, radius: CGFloat, rim: Rim = .legacy) {
        let shape = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        ctx.saveGState()
        shape.addClip()
        let white = UIColor.white
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        for (stops, fromTop) in [(rim.top, true), (rim.bottom, false)] {
            // cmux: no force unwraps (crash program); an empty rim or a failed gradient draws nothing.
            guard let span = stops.last?.0 else { continue }
            let g = CGGradient(colorsSpace: space, colors: stops.map { white.withAlphaComponent($0.1).cgColor } as CFArray,
                               locations: stops.map { $0.0 / span })
            let y0 = fromTop ? rect.minY : rect.maxY
            let y1 = fromTop ? rect.minY + span : rect.maxY - span
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
        }
        ctx.restoreGState()
        // Dark side edges.
        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: -1, dy: min(radius, rect.height / 2) * 0.5))
        UIColor(white: 0, alpha: 0.6).setStroke()
        let edge = UIBezierPath(roundedRect: rect.insetBy(dx: -0.25, dy: -0.25), cornerRadius: radius + 0.25)
        edge.lineWidth = 0.5
        edge.stroke()
        ctx.restoreGState()
    }
}
