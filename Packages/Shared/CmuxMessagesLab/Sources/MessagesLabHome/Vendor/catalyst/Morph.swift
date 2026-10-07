#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Accelerate

/// The send morph: the compose field turns into the new bubble.
///
/// Layers (window coordinates):
/// - `holder`: full-window, carries later transcript shifts (position.y) and
///   hides the morph at the landing time (render-server timed).
/// - `bubble`: anchor at its right edge, vertical center. Animated: right
///   edge (position.x), center (position.y), scale pulse, opacity.
/// - `body`: the rounded blue body, frame (-w, 0, w, h) in `bubble`, so the
///   width change moves only its left edge. It clips the text.
/// - `text` / `blurred`: the bubble's text, left aligned in the body; the
///   blurred copy fades out as the sharp text fades in.
/// - `tail`: fixed at the right-bottom corner.
final class MorphBubble {
    let key: String
    let holder = CALayer()
    let bubble = CALayer()
    let body = CALayer()
    let text = CALayer()
    let blurred = CALayer()
    let tail = CAShapeLayer()
    let underlay = CALayer()
    /// The same bubble with sharp text, shown only OUTSIDE the field glass
    /// (`sharpClip`'s mask): Messages' text is sharp from the first frame; only
    /// the glass blurs the part still inside the field (lossless
    /// typing-unfocused-take1: the second line of a 2-line bubble hangs below
    /// the field, sharp). Inside the field the main tree's blurred copy shows.
    let sharpClip = CALayer()
    /// Holds `holder`: masked to the field glass once `clipGlass` runs, so the two
    /// trees never draw the same pixel (no doubled translucent body).
    let insideClip = CALayer()
    private let glassInside = CALayer()
    let sharpHolder = CALayer()
    private let sharpParts: (bubble: CALayer, body: CALayer, text: CALayer, tail: CAShapeLayer, underlay: CALayer)
    private let glassAbove = CALayer()
    let landTime: CFTimeInterval
    private let textLayout: TextLayout
    private let textSize: CGSize
    private let fieldRect: CGRect, flyingRect: CGRect

    /// Kept for callers; the morph no longer uses Core Image.
    static func warmUp() {}

    init(key: String, in parent: CALayer, windowBounds: CGRect, from field: CGRect, to target: CGRect,
         textLayout tl: TextLayout, size: CGSize, begin: CFTimeInterval) {
        self.key = key
        textLayout = tl
        textSize = size
        fieldRect = field
        flyingRect = target
        let none: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(),
                                        "transform": NSNull(), "path": NSNull(), "backgroundColor": NSNull()]
        for l in [holder, bubble, body, text, blurred, tail, underlay] { l.actions = none; l.contentsScale = Fixture.renderScale }
        holder.frame = windowBounds
        insideClip.actions = none
        insideClip.frame = windowBounds
        insideClip.addSublayer(holder)
        // Below the compose glass overlay (Messages draws the field's glass,
        // placeholder and microphone over a bubble still inside the field).
        if let o = parent.sublayers?.first(where: { $0.name == "composeGlassOverlay" }) {
            parent.insertSublayer(insideClip, below: o)
        } else {
            parent.addSublayer(insideClip)
        }

        let color = MorphBubble.blue(atWindowY: target.midY)
        // Final geometry (model values).
        let w1 = target.width, h1 = target.height
        // Start: the field's width and top edge, and the taller of the field and the bubble.
        // A draft on fewer lines than its bubble starts at the bubble's height and hangs
        // below the field (macOS 27, lossless typing-unfocused-take1: the 2-line bubble
        // of a 1-line draft starts at the field top, its second line under the field);
        // a draft on more lines starts at the field's height (send-typed-take1).
        let w0 = field.width, h0 = max(field.height, h1)
        let y0 = field.minY + h0 / 2
        let o = Springs.bubbleOpacity
        let images = MorphBubble.preparedImages(tl, size) ?? MorphBubble.textImages(tl, size)
        /// One bubble tree (the main one, or the sharp copy) with every spring.
        func build(_ bubble: CALayer, _ body: CALayer, _ text: CALayer, _ tail: CAShapeLayer, _ underlay: CALayer, in holder: CALayer, blurred: CALayer?) {
            bubble.anchorPoint = CGPoint(x: 1, y: 0.5)
            bubble.bounds = CGRect(x: -w1, y: 0, width: w1, height: h1)
            bubble.position = CGPoint(x: target.maxX, y: target.midY)
            holder.addSublayer(bubble)
            body.backgroundColor = color.cgColor
            body.cornerRadius = Fixture.bubbleRadius
            body.masksToBounds = true
            body.bounds = CGRect(x: 0, y: 0, width: w1, height: h1)
            body.position = CGPoint(x: -w1 / 2, y: h1 / 2)
            // While translucent, the bubble shows a dark grey under it (MorphBubble.underlayGrey).
            // Fitted on the lossless send takes (catalyst/TRANSITIONS.md, "Field glass underlay").
            underlay.backgroundColor = UIColor(white: MorphBubble.underlayGrey / 255, alpha: 1).cgColor
            underlay.cornerRadius = Fixture.bubbleRadius
            underlay.bounds = body.bounds
            underlay.position = body.position
            bubble.addSublayer(underlay)
            bubble.addSublayer(body)
            // Tail at the right-bottom corner (outgoing shape of BubblePath).
            let t = BubblePath.tailPath(outgoing: true)
            t.apply(CGAffineTransform(translationX: 0, y: h1))
            tail.path = t.cgPath
            tail.fillColor = color.cgColor
            tail.frame = CGRect(x: -w1, y: 0, width: w1, height: h1)
            tail.bounds = CGRect(x: -w1, y: 0, width: w1, height: h1)
            bubble.addSublayer(tail)
            // Text images drawn as the bubble draws them, at the LARGEST size they
            // reach on screen (the scale pulse overshoots 1 slightly), so the
            // layer only ever scales them down (resolution brief: no upscaled
            // snapshot during an animation).
            text.contents = images.0
            text.frame = CGRect(origin: .zero, size: size)
            body.addSublayer(text)
            if let blurred {
                // The blurred copy has room for its glow (no hard edge where the
                // text image ends: the reference shows none).
                blurred.contents = images.1
                blurred.frame = text.frame.insetBy(dx: -MorphBubble.blurPad, dy: -MorphBubble.blurPad)
                body.addSublayer(blurred)
                blurred.opacity = Animate.hiddenOpacity
            }
            bubble.opacity = 1

            // Springs (springs.json). Positions in points; the fits are in 2x px.
            Animate.scalar(bubble, "position.x", from: Double(field.maxX), to: Double(target.maxX), Springs.bubbleRight, begin: begin)
            Animate.scalar(bubble, "position.y", from: Double(y0), to: Double(target.midY), Springs.bubbleCenterY, begin: begin)
            for l in [body, underlay] {
                Animate.scalar(l, "bounds.size.width", from: Double(w0), to: Double(w1), Springs.bubbleWidth, begin: begin)
                Animate.scalar(l, "position.x", from: Double(-w0 / 2), to: Double(-w1 / 2), Springs.bubbleWidth, begin: begin)
                Animate.scalar(l, "bounds.size.height", from: Double(h0), to: Double(h1), Springs.bubbleWidth, begin: begin)
                Animate.scalar(l, "position.y", from: Double(h0 / 2), to: Double(h1 / 2), Springs.bubbleWidth, begin: begin)
            }
            Animate.scalar(tail, "position.y", from: Double(h1 / 2 + (h0 - h1) / 2), to: Double(h1 / 2), Springs.bubbleWidth, begin: begin)
            Animate.pulse(bubble, "transform.scale", Springs.bubbleScale, begin: begin)
            Animate.scalar(body, "opacity", from: o.from, to: 1, o, begin: begin)
            Animate.scalar(tail, "opacity", from: o.from, to: 1, o, begin: begin)
            // The grey under the translucent bubble belongs to the bubble, not to
            // the field glass: it stays while the glass fill fades (measured at
            // 0256: blue at 0.76 over grey about 70, with the glass fill gone).
            // Once the body is opaque it is covered.
            if let blurred {
                Animate.scalar(text, "opacity", from: 0, to: 1, Springs.textUnblur, begin: begin)
                Animate.scalar(blurred, "opacity", from: 1, to: 0, Springs.textUnblur, begin: begin)
            }
        }
        build(bubble, body, text, tail, underlay, in: holder, blurred: blurred)
        // The sharp copy, clipped to everything but the field glass (the glass's top edge
        // follows the field's own motion: `clipGlass`). Without that call it shows nothing.
        let sp = (bubble: CALayer(), body: CALayer(), text: CALayer(), tail: CAShapeLayer(), underlay: CALayer())
        sharpParts = sp
        for l in [sharpClip, sharpHolder, glassAbove, sp.bubble, sp.body, sp.text, sp.tail, sp.underlay] { l.actions = none; l.contentsScale = Fixture.renderScale }
        sharpClip.frame = windowBounds
        sharpHolder.frame = windowBounds
        sharpClip.addSublayer(sharpHolder)
        let mask = CALayer()
        mask.frame = sharpClip.bounds
        mask.actions = none
        sharpClip.mask = mask
        insideClip.superlayer?.insertSublayer(sharpClip, above: insideClip)
        build(sp.bubble, sp.body, sp.text, sp.tail, sp.underlay, in: sharpHolder, blurred: nil)

        // Land: when every component has settled, the cell (same pixels) shows
        // and the morph hides, both on the render server's clock.
        // Land when every element is within 0.1 pt (opacity 0.01) of its final
        // value: then the overlay and the cell show the same pixels.
        let checks: [(SpringElement, Double, Double, Double)] = [
            (Springs.bubbleRight, Double(field.maxX), Double(target.maxX), 0.1),
            (Springs.bubbleCenterY, Double(y0), Double(target.midY), 0.1),
            (Springs.bubbleWidth, Double(w0), Double(w1), 0.1),
            (Springs.bubbleScale, 1, 1, 0.1 / Double(max(w1, h1))),
            (o, o.from, 1, 0.01), (Springs.textUnblur, 0, 1, 0.01)]
        // The first 1/120 s step from 0.3 s with 12 steps in a row inside every
        // tolerance (each step's checks evaluated once; same result as testing
        // 12 steps per candidate, about 12x less spring math on the send commit).
        let steps = Int(((2.0 - 0.3) * 120).rounded(.up))
        var ok = [Bool](repeating: false, count: steps + 12)
        for i in ok.indices {
            let tau = 0.3 + Double(i) / 120
            ok[i] = checks.allSatisfy { e, a, b, tol in abs(e.value(tau, from: a, to: b) - b) <= tol }
        }
        var first = steps
        var run = 0
        for i in ok.indices {
            run = ok[i] ? run + 1 : 0
            if run == 12 { first = i - 11; break }
        }
        let settle = 0.3 + Double(min(first, steps)) / 120
        landTime = begin + settle
        // The overlay is removed at landTime (WindowView.settle); the cell
        // shows from the same time, with the same pixels.
    }

    /// Text and its blurred copy at the current render scale, at the largest
    /// size they reach on screen. Blur at the text image's own resolution
    /// (never an upscaled snapshot): three box passes with Accelerate
    /// approximate the sigma-5 Gaussian it replaces; no Core Image.
    /// Margin around the blurred text: three box passes of radius 4.5 pt
    /// spread about 13.5 pt.
    static let blurPad: CGFloat = 14
    /// The grey (0-255) under the translucent flying bubble: 34, fitted inside the field glass on
    /// the lossless send takes against two takes of ours at 76 and 30 (was 76, fitted on the lossy
    /// 4:2:0 original). In DEV and self-test builds only, MORPH_UNDERLAY overrides it for A/B takes.
    #if DEBUG || MESSAGESLAB_SELFTEST
    static let underlayGrey: CGFloat = ProcessInfo.processInfo.environment["MORPH_UNDERLAY"].flatMap { Double($0) }.map { CGFloat($0) } ?? 34
    #else
    static let underlayGrey: CGFloat = 34
    #endif

    /// The send frame's text and blur, prepared off main while the draft changes (the same
    /// layout the send derives: trimmed text, TextParts, Sizing at the window width). The
    /// send uses them only for an equal layout, size and scale; else it renders as before.
    private static let prepQueue = DispatchQueue(label: "morph.prepare", qos: .userInitiated)
    private static let prepLock = NSLock()
    private static var prepared: (tl: TextLayout, size: CGSize, scale: CGFloat, images: (CGImage?, CGImage?))?
    private static var prepSerial = 0
    static var preparedHits = 0
    static func prepare(draft: String, width: CGFloat) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !LongText.isLong(t) else { return }
        prepLock.lock(); prepSerial += 1; let serial = prepSerial; prepLock.unlock()
        let scale = Fixture.renderScale
        prepQueue.async {
            prepLock.lock(); let latest = serial == prepSerial; prepLock.unlock()
            guard latest, let part = TextParts.parts(for: t).first(where: { $0.plainText != nil }) else { return }
            let (size, tl) = Sizing.size(of: part, width: width)
            guard let tl, scale == Fixture.renderScale else { return }
            let images = textImages(tl, size)
            prepLock.lock()
            if serial == prepSerial { prepared = (tl, size, scale, images) }
            prepLock.unlock()
        }
    }
    private static func preparedImages(_ tl: TextLayout, _ size: CGSize) -> (CGImage?, CGImage?)? {
        prepLock.lock(); defer { prepLock.unlock() }
        guard let p = prepared, p.size == size, p.scale == Fixture.renderScale, p.tl == tl else { return nil }
        preparedHits += 1
        return p.images
    }

    private static func textImages(_ tl: TextLayout, _ size: CGSize) -> (CGImage?, CGImage?) {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = Fixture.renderScale * MorphBubble.peakScale
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            PartRenderer.drawText(ctx.cgContext, tl, in: CGRect(origin: .zero, size: size), outgoing: true)
        }
        let p = blurPad
        let padded = UIGraphicsImageRenderer(size: CGSize(width: size.width + 2 * p, height: size.height + 2 * p), format: fmt).image { ctx in
            PartRenderer.drawText(ctx.cgContext, tl, in: CGRect(x: p, y: p, width: size.width, height: size.height), outgoing: true)
        }
        return (img.cgImage, padded.cgImage.flatMap { MorphBubble.boxBlur($0, radiusPx: Int((9 * Fixture.renderScale / 2).rounded())) })
    }

    /// The body's bottom edge in window points, `tau` seconds after the send
    /// (closed form of the same elements the layers run).
    func bottom(at tau: Double) -> Double {
        let h1 = Double(flyingRect.height), h0 = max(Double(fieldRect.height), h1)
        let cy = Springs.bubbleCenterY.value(tau, from: Double(fieldRect.minY) + h0 / 2, to: Double(flyingRect.midY))
        let s = Springs.bubbleScale.value(tau, from: 1, to: 1)
        let h = Springs.bubbleWidth.value(tau, from: h0, to: h1)
        return cy + (h - h1 / 2) * s
    }

    /// The sharp copy shows everywhere but the field glass: above the field's top
    /// edge (which moves from `topFrom` to `topTo` with the field's spring), below
    /// its bottom and beside it. (The glass's 15 pt corners are not cut out.)
    func clipGlass(field: CGRect, topFrom: Double, topTo: Double, begin: CFTimeInterval) {
        guard let mask = sharpClip.mask else { return }
        let none: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        let W = sharpClip.bounds.width, H = sharpClip.bounds.height
        func rect(_ r: CGRect) -> CALayer {
            let l = CALayer(); l.actions = none; l.backgroundColor = UIColor.black.cgColor; l.frame = r; mask.addSublayer(l); return l
        }
        _ = rect(CGRect(x: 0, y: field.maxY, width: W, height: max(0, H - field.maxY)))
        _ = rect(CGRect(x: 0, y: 0, width: max(0, field.minX), height: H))
        _ = rect(CGRect(x: field.maxX, y: 0, width: max(0, W - field.maxX), height: H))
        glassAbove.actions = none
        glassAbove.backgroundColor = UIColor.black.cgColor
        glassAbove.anchorPoint = .zero
        glassAbove.position = .zero
        glassAbove.bounds = CGRect(x: 0, y: 0, width: W, height: CGFloat(topTo))
        mask.addSublayer(glassAbove)
        Animate.scalar(glassAbove, "bounds.size.height", from: topFrom, to: topTo, Springs.fieldTop, begin: begin)
        // The main tree (blurred copy fading to sharp) only inside the glass: its
        // bottom edge fixed, its top edge with the field's.
        let inside = CALayer()
        inside.actions = none
        inside.frame = insideClip.bounds
        glassInside.actions = none
        glassInside.backgroundColor = UIColor.black.cgColor
        glassInside.anchorPoint = CGPoint(x: 0, y: 1)
        glassInside.position = CGPoint(x: field.minX, y: field.maxY)
        glassInside.bounds = CGRect(x: 0, y: 0, width: field.width, height: field.maxY - CGFloat(topTo))
        inside.addSublayer(glassInside)
        insideClip.mask = inside
        Animate.scalar(glassInside, "bounds.size.height", from: Double(field.maxY) - topFrom, to: Double(field.maxY) - topTo, Springs.fieldTop, begin: begin)
    }

    /// A display-scale change during the flight (the window moved to another
    /// screen): re-rasterize at the new scale; the animations keep running.
    func rescale() {
        let sp = sharpParts
        for l in [holder, bubble, body, text, blurred, tail, underlay, insideClip, sharpClip, sharpHolder, sp.bubble, sp.body, sp.text, sp.tail, sp.underlay] {
            l.contentsScale = Fixture.renderScale
        }
        (text.contents, blurred.contents) = MorphBubble.textImages(textLayout, textSize)
        sp.text.contents = text.contents
    }

    /// A later transcript shift moves the target slot: same additive motion as the row.
    func shift(by dy: Double, _ element: SpringElement, begin: CFTimeInterval) {
        guard abs(dy) > 0.01 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for h in [holder, sharpHolder] { h.position.y -= CGFloat(dy) }
        CATransaction.commit()
        for h in [holder, sharpHolder] {
            Animate.scalar(h, "position.y", from: Double(h.position.y) + dy, to: Double(h.position.y), element, begin: begin)
        }
    }

    /// User scroll during the flight (no animation).
    func scroll(by dy: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        holder.position.y -= dy
        sharpHolder.position.y -= dy
        CATransaction.commit()
    }

    func remove() { insideClip.removeFromSuperlayer(); sharpClip.removeFromSuperlayer() }

    /// The largest value of the fitted scale pulse (sampled at 240 Hz).
    static let peakScale: CGFloat = {
        let e = Springs.bubbleScale
        var peak = 1.0
        for i in 0..<Int(max(1, e.settleTime) * 240) { peak = max(peak, e.value(Double(i) / 240, from: 1, to: 1)) }
        return CGFloat((peak * 1000).rounded(.up) / 1000)
    }()

    /// Three box-convolution passes (about a Gaussian), at the source's pixel size.
    static func boxBlur(_ cg: CGImage, radiusPx r: Int) -> CGImage? {
        guard var format = vImage_CGImageFormat(cgImage: cg),
              var src = try? vImage_Buffer(cgImage: cg, format: format),
              var dst = try? vImage_Buffer(width: Int(src.width), height: Int(src.height), bitsPerPixel: format.bitsPerPixel) else { return nil }
        defer { src.free(); dst.free() }
        let k = UInt32(2 * r + 1)
        for _ in 0..<3 {
            vImageBoxConvolve_ARGB8888(&src, &dst, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
            swap(&src, &dst)
        }
        return try? src.createCGImage(format: format)
    }

    /// The outgoing gradient's colour at a window y (pt).
    static func blue(atWindowY y: CGFloat) -> UIColor {
        let px = y * 2
        // cmux: a themed accent interpolates its own stops.
        if let t = Fixture.themedGradient { return Fixture.color(in: t, atPx: px) }
        let s = Fixture.gradientStops
        var i = 1
        while i < s.count - 1, s[i].0 < px { i += 1 }
        let a = s[i - 1], b = s[i]
        let f = max(0, min(1, (px - a.0) / max(1, b.0 - a.0)))
        return Fixture.gradientColor(a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }
}
