#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Message bubble outline: a rounded body plus the small hanging tail.
enum BubblePath {
    /// UIKit's rounded rect uses its limited (pill) corner when half the height is under this times the radius.
    static let pillLimit: CGFloat = 1.528665
    /// Bubble outlines by size (cells reuse them for the gradient mask).
    private static var cache: [Key: CGPath] = [:]
    private struct Key: Hashable { var w: CGFloat; var h: CGFloat; var outgoing: Bool; var tail: Bool; var cw: CGFloat = 0; var ch: CGFloat = 0
        var circularEnds = false }
    /// The bubble outline at the origin (main thread). `cornersOf`, `circularEnds`: as `make`.
    static func cached(size: CGSize, outgoing: Bool, tail: Bool, cornersOf frame: CGSize? = nil, circularEnds: Bool = false) -> CGPath {
        let k = Key(w: size.width, h: size.height, outgoing: outgoing, tail: tail, cw: frame?.width ?? 0, ch: frame?.height ?? 0,
                    circularEnds: circularEnds)
        if let p = cache[k] { return p }
        if cache.count > 2000 { cache.removeAll() }
        let p = make(body: CGRect(origin: .zero, size: size), outgoing: outgoing, tail: tail, cornersOf: frame, circularEnds: circularEnds).cgPath
        cache.updateValue(p, forKey: k)
        return p
    }
    /// `cornersOf`: the body takes the rounded rect of this size, scaled to `r` (an outgoing text balloon drawn a
    /// little inside its frame, RowDraw.balloon). It keeps its frame's corners: UIKit's rounded rect switches to
    /// its limited (pill) corner when half the height is under 1.528665 r (UIKitRoundedRect), 45.86 pt for r = 15,
    /// so a 45.62 pt balloon built at its own size had pill corners (radius about 22.8 pt; Messages' 2-line
    /// balloon keeps its 15 pt continuous corner: deactivate-activate/tp1200ms.png). The tail is not scaled.
    ///
    /// `circularEnds`: a body whose half height is under UIKit's limit (1.528665 r) ends in exact half circles
    /// (radius half the shorter side) instead of UIKit's pill corner. Real Messages (macOS 27) draws its 1-line
    /// incoming text balloon so (RowDraw.circularEnds): every 30 pt incoming balloon in deactivate-activate,
    /// bubble-kinds-scene, typing-dots-01 and state-204892 fits a circle of radius 15 pt within 0.05 px rms per
    /// device pixel row (tails excluded), its left edge 40.00 px on every row through the middle. Its 1-line outgoing
    /// balloon too (soft-edge: the pill corner up to 0.68 px fuller near the top and bottom of the end). UIKit's pill
    /// corner is up to 0.76 px fuller (0.5 px on average) and reaches 0.14 px past the frame at the middle (the
    /// 39.87 px left edges of tools/evidence/anim/rowxedge.py; tools/evidence/ANIMATIONS.md section 6, cx-3cb
    /// incoming-edge). Taller bodies keep UIKit's continuous corner, which Messages' 2-line balloon matches.
    static func make(body r: CGRect, outgoing: Bool, tail: Bool, radius: CGFloat = Fixture.bubbleRadius,
                     cornersOf frame: CGSize? = nil, circularEnds: Bool = false) -> UIBezierPath {
        let path: UIBezierPath
        if circularEnds, r.width > 0, r.height > 0, r.height / 2 < pillLimit * radius {
            let q = min(r.width, r.height) / 2
            path = UIBezierPath(cgPath: CGPath(roundedRect: r, cornerWidth: q, cornerHeight: q, transform: nil))
        } else if let f = frame, f != r.size, f.width > 0, f.height > 0 {
            let full = UIBezierPath(roundedRect: CGRect(origin: .zero, size: f), cornerRadius: min(radius, f.height / 2)).cgPath
            var xf = CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: r.width / f.width, y: r.height / f.height)
            path = full.copy(using: &xf).map { UIBezierPath(cgPath: $0) } ?? UIBezierPath(roundedRect: r, cornerRadius: min(radius, r.height / 2))
        } else {
            path = UIBezierPath(roundedRect: r, cornerRadius: min(radius, r.height / 2))
        }
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

/// Messages' soft outgoing balloon edge (macOS 27, cx-3cb soft-edge; tools/evidence/ANIMATIONS.md section 1 "soft-edge",
/// tools/evidence/anim/softedge/). Messages anti-aliases every flat edge of an outgoing text balloon over two partly
/// covered device px (outer / inner coverage: 2+ lines top and left .212 / .871, bottom and right .235-.240 / .926; 1 line
/// top .124 / .921, bottom .783 / .991), the same in every balloon of every width and height and in `screencapture -l`
/// stills, where a crisp edge at the same place covers one px (.08 / 1). A crisp balloon drawn a sub-pixel distance
/// away and moved back with linear filtering (a bitmap placed at a fractional position) gives that profile within
/// 0.03 on every edge with one shift per kind: 2+ lines drawn 0.225 px up and left and moved back right and down,
/// 1 line drawn 0.14 px down and right and moved back up and left. The summed coverage (the edge place of
/// RowDraw.balloon) does not change. Main thread only (the cache).
///
/// The cell masks its fill with a precomputed image of that balloon (one per kind, tail and screen scale, built once)
/// stretched by Core Animation along its flat middle (`contentsCenter`): the caps keep their pixels 1:1 on the
/// whole-pixel grid of the frame, so the per-frame cost is one image mask on the GPU, as the shape mask before; no
/// path is filled or blurred per frame or per cell.
enum SoftBalloon {
    struct Mask { let image: CGImage; let frame: CGRect; let center: CGRect }
    private enum Kind: Int { case one, two, more }
    private struct Template { let image: CGImage; let center: CGRect }
    /// `narrow`: a balloon narrower than its caps gets its own unstretched image (its width and left phase in device px).
    private struct Key: Hashable { let kind: Int; let tail: Bool; let scale: CGFloat; var narrow: [Int] = []; var circularEnds = false }
    private static var cache: [Key: Template] = [:]
    /// Space around the frame (pt) and below it for the tail (it hangs 5.14 pt below the balloon).
    static let pad: CGFloat = 1, tailDrop: CGFloat = 6
    /// Template frames: 30 pt (1 line), 46 (2 lines), 62 (3 lines; taller rows stretch the middle row).
    private static func templateHeight(_ k: Kind) -> CGFloat { k == .one ? 30 : k == .two ? 46 : 62 }
    /// The filter's move in device px (+ right and down; the crisp balloon is drawn at -d; fit.py constrained "bilinear").
    private static func shift(_ k: Kind) -> CGFloat { k == .one ? -0.14 : 0.225 }
    /// Caps (pt from the frame's left / right): the corner (UIKit's continuous corner reaches 1.528665 r = 22.93 pt for
    /// r = 15; the 1-line pill 15 pt) and the tail (16 pt from the right).
    private static func caps(_ k: Kind) -> (CGFloat, CGFloat) { k == .one ? (20, 20) : (23.5, 23.5) }

    /// The mask for an outgoing text part with body frame `f` (row coordinates, whole device px), or nil (the crisp
    /// shape mask): a row without the inset (RowDraw.insetApplies) or a height that is not 30, 46 or 62+ pt.
    /// `scale`: the cell's (its window view's renderScale); the templates are cached per scale.
    static func mask(frame f: CGRect, row p: PartRow, scale: CGFloat = Fixture.renderScale) -> Mask? {
        guard RowDraw.insetApplies(p) else { return nil }
        let s = scale
        let k: Kind
        let h = f.height
        if abs(h - templateHeight(.one)) < 0.01 { k = .one }
        else if abs(h - templateHeight(.two)) < 0.01 { k = .two }
        else if h > templateHeight(.more) - 0.01 { k = .more }
        else { return nil }
        let left = floor(f.minX * s + 0.001) / s
        let (cl, cr) = caps(k)
        // Narrower than the caps (a short 1-line reply, a narrow 2-line balloon): an image of exactly this balloon.
        let narrow = f.maxX - left < cl + cr + 1 / s
            ? [CrashGuard.int(((f.maxX - left) * s).rounded(), in: 0...16_384), CrashGuard.int(((f.minX - left) * s * 1000).rounded(), in: 0...16_384)] : []
        guard let t = template(k, tail: p.tail, scale: s, narrow: narrow, frame: f.offsetBy(dx: -left, dy: -f.minY),
                               circularEnds: RowDraw.circularEnds(p)) else { return nil }
        let frame = CGRect(x: left - pad, y: f.minY - pad, width: f.maxX - left + 2 * pad,
                           height: f.height + tailDrop + 2 * pad)
        return Mask(image: t.image, frame: frame, center: t.center)
    }

    /// Clips `ctx` (a y-down row drawing context at `scale`) to the soft mask of the outgoing text part with body frame
    /// `f`, the pixels the cell's mask layer shows (cx-3cb soft-copies: the row copies with a window y, as the thread
    /// view and the highlight, draw the resting balloon's soft edge). false (ctx unchanged): no soft mask for this part
    /// (the caller draws the crisp shape). The caller saves and restores the state around it.
    static func clip(_ ctx: CGContext, frame f: CGRect, row p: PartRow, scale: CGFloat = Fixture.renderScale) -> Bool {
        guard !crispCopy, let m = mask(frame: f, row: p, scale: scale), let gray = image(of: m, scale: scale) else { return false }
        // The mask image's first row is the frame's top: in a y-down context the image is drawn flipped about the frame.
        let r = m.frame
        let flipped = ctx.ctm.d < 0
        let flip = CGAffineTransform(translationX: 0, y: r.minY + r.maxY).scaledBy(x: 1, y: -1)
        if flipped { ctx.concatenate(flip) }
        ctx.clip(to: r, mask: gray)
        if flipped { ctx.concatenate(flip.inverted()) }
        return true
    }

    /// Main thread: inside `withCrispCopy(true)` `clip` returns false (a copy of a just-sent row: RowCell.crispEdge).
    private static var crispCopy = false
    static func withCrispCopy(_ on: Bool, _ body: () -> Void) {
        let was = crispCopy; crispCopy = on; defer { crispCopy = was }
        body()
    }

    /// The mask as one unstretched DeviceGray image (no alpha: CGContext.clip(to:mask:)), its caps 1:1 and its stretched
    /// column and row repeated as Core Animation stretches them (`contentsCenter`; a 3+ line balloon's stretched row
    /// lies in its flat sides, so either count of the unit rect gives these pixels).
    private static func image(of m: Mask, scale s: CGFloat) -> CGImage? {
        let src = m.image
        let sw = src.width, sh = src.height
        // Larger than a bitmap may be: no soft copy (the caller draws the crisp shape).
        let fw = (m.frame.width * s).rounded(), fh = (m.frame.height * s).rounded()
        guard fw >= 1, fh >= 1, fw <= 16_384, fh <= 16_384 else { return nil }
        let W = CrashGuard.int(fw, in: 1...16_384), H = CrashGuard.int(fh, in: 1...16_384)
        // The stretched px: `center` is (index / size), so the nearest index (a floor could land one px early).
        let cx = CrashGuard.int((m.center.minX * CGFloat(sw)).rounded(), in: 0...max(0, sw - 1))
        let cy = CrashGuard.int((m.center.minY * CGFloat(sh)).rounded(), in: 0...max(0, sh - 1))
        guard W >= sw - 1, H >= sh - 1,
              let g = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        g.interpolationQuality = .none
        g.setFillColor(gray: 0, alpha: 1)
        g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Source spans (top-left px) and their destination spans: before the stretched px, it (repeated), after it.
        func spans(_ n: Int, _ c: Int, _ out: Int) -> [(Int, Int, Int, Int)] { // (src start, src len, dst start, dst len)
            let rep = out - (n - 1)
            return [(0, c, 0, c), (c, 1, c, max(0, rep)), (c + 1, n - c - 1, c + max(0, rep), n - c - 1)].filter { $0.1 > 0 && $0.3 > 0 }
        }
        for (sx, sl, dx, dl) in spans(sw, cx, W) {
            for (sy, sk, dy, dk) in spans(sh, cy, H) {
                guard let piece = src.cropping(to: CGRect(x: sx, y: sy, width: sl, height: sk)) else { continue }
                // CG's y is up: a destination span dk rows from the top starts H - dy - dk rows from the bottom.
                g.draw(piece, in: CGRect(x: dx, y: H - dy - dk, width: dl, height: dk))
            }
        }
        return g.makeImage()
    }

    /// `f`: the body frame relative to its whole-px left edge and its top (used only for a narrow balloon).
    /// `circularEnds`: a 1-line balloon with half-circle ends (BubblePath.make, RowDraw.circularEnds).
    private static func template(_ k: Kind, tail: Bool, scale s: CGFloat, narrow: [Int], frame f: CGRect, circularEnds: Bool) -> Template? {
        let key = Key(kind: k.rawValue, tail: tail, scale: s, narrow: narrow, circularEnds: circularEnds)
        if let t = cache[key] { return t }
        if cache.count > 200 { cache = cache.filter { $0.key.narrow.isEmpty } }
        let (cl, cr) = caps(k)
        let fh = templateHeight(k)
        let frame = narrow.isEmpty ? CGRect(x: 0, y: 0, width: 200, height: fh) : CGRect(x: f.minX, y: 0, width: f.width, height: fh)
        let size = CGSize(width: frame.maxX + 2 * pad, height: fh + tailDrop + 2 * pad)
        let w = CrashGuard.int((size.width * s).rounded(), in: 1...16_384), h = CrashGuard.int((size.height * s).rounded(), in: 1...16_384)
        func context(_ width: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = context(w) else { return nil }
        let d = shift(k)
        // Top-down rows in point space; the crisp balloon drawn at -d px (d > 0: up and left).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: pad - d / s, y: pad - d / s)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(BubblePath.make(body: RowDraw.insetBalloon(frame, scale: s), outgoing: true, tail: tail, cornersOf: frame.size,
                                    circularEnds: circularEnds).cgPath)
        ctx.fillPath()
        // Moved back by d with linear filtering, separable: out = (1 - |d|) src + |d| src moved one whole device px
        // (no interpolation; the two copies add), along x, then along y.
        let wd = abs(d), sgn: CGFloat = d > 0 ? 1 : -1
        func blend(_ img: CGImage, dx: CGFloat, dy: CGFloat) -> CGImage? {
            guard let c = context(w) else { return nil }
            c.interpolationQuality = .none
            let r = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            c.setAlpha(1 - wd); c.draw(img, in: r)
            c.setBlendMode(.plusLighter); c.setAlpha(wd)
            c.draw(img, in: r.offsetBy(dx: dx, dy: -dy))   // CG's y is up: a row down is -1
            return c.makeImage()
        }
        guard let crisp = ctx.makeImage(), let across = blend(crisp, dx: sgn, dy: 0),
              let soft = blend(across, dx: 0, dy: sgn) else { return nil }
        // The image: the left cap and one stretched device px column, then the right cap (the template is wider than
        // that so that its corners take the scale of a common balloon in BubblePath.make cornersOf). A narrow
        // balloon's image is the whole template (its layer is as wide: nothing stretches).
        let cx = narrow.isEmpty ? CrashGuard.int(((pad + cl) * s).rounded(), in: 0...w) : w / 2
        let rc = narrow.isEmpty ? CrashGuard.int(((cr + pad) * s).rounded(), in: 0...w) : w - cx - 1
        let w2 = cx + 1 + rc
        guard w2 <= w, let out = context(w2) else { return nil }
        out.interpolationQuality = .none
        let full = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        out.saveGState()
        out.clip(to: CGRect(x: 0, y: 0, width: CGFloat(cx + 1), height: CGFloat(h)))
        out.draw(soft, in: full)
        out.restoreGState()
        out.clip(to: CGRect(x: CGFloat(cx + 1), y: 0, width: CGFloat(rc), height: CGFloat(h)))
        out.draw(soft, in: full.offsetBy(dx: CGFloat(w2 - w), dy: 0))
        guard let image = out.makeImage() else { return nil }
        // The stretched row (3+ lines): one device px in the image's middle, inside the flat part of the sides whether
        // the unit rect counts from the top or the bottom (flat 24-40 pt from the top of a 70 pt image).
        let cy = h / 2
        let center = CGRect(x: CGFloat(cx) / CGFloat(w2), y: CGFloat(cy) / CGFloat(h), width: 1 / CGFloat(w2), height: 1 / CGFloat(h))
        let t = Template(image: image, center: center)
        cache[key] = t
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
            // no force unwraps ; an empty rim or a failed gradient draws nothing.
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
