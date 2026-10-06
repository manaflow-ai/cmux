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
        // Below the compose glass overlay (Messages draws the field's glass,
        // placeholder and microphone over a bubble still inside the field).
        if let o = parent.sublayers?.first(where: { $0.name == "composeGlassOverlay" }) {
            parent.insertSublayer(holder, below: o)
        } else {
            parent.addSublayer(holder)
        }

        let color = MorphBubble.blue(atWindowY: target.midY)
        // Final geometry (model values).
        let w1 = target.width, h1 = target.height
        bubble.anchorPoint = CGPoint(x: 1, y: 0.5)
        bubble.bounds = CGRect(x: -w1, y: 0, width: w1, height: h1)
        bubble.position = CGPoint(x: target.maxX, y: target.midY)
        holder.addSublayer(bubble)
        body.backgroundColor = color.cgColor
        body.cornerRadius = Fixture.bubbleRadius
        body.masksToBounds = true
        body.bounds = CGRect(x: 0, y: 0, width: w1, height: h1)
        body.position = CGPoint(x: -w1 / 2, y: h1 / 2)
        // While translucent, the bubble shows the field's glass grey under it
        // (measured per frame 0250-0253 with the glass above the bubble: blue at
        // the bubble's opacity over grey 76, the underlay fading with the glass).
        underlay.backgroundColor = UIColor(white: 76 / 255, alpha: 1).cgColor
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
        (text.contents, blurred.contents) = MorphBubble.textImages(tl, size)
        text.frame = CGRect(origin: .zero, size: size)
        body.addSublayer(text)
        // The blurred copy has room for its glow (no hard edge where the
        // text image ends: the reference shows none).
        blurred.frame = text.frame.insetBy(dx: -MorphBubble.blurPad, dy: -MorphBubble.blurPad)
        body.addSublayer(blurred)
        blurred.opacity = Animate.hiddenOpacity
        bubble.opacity = 1

        // Springs (springs.json). Positions in points; the fits are in 2x px.
        let w0 = field.width, h0 = field.height
        Animate.scalar(bubble, "position.x", from: Double(field.maxX), to: Double(target.maxX), Springs.bubbleRight, begin: begin)
        Animate.scalar(bubble, "position.y", from: Double(field.midY), to: Double(target.midY), Springs.bubbleCenterY, begin: begin)
        Animate.scalar(body, "bounds.size.width", from: Double(w0), to: Double(w1), Springs.bubbleWidth, begin: begin)
        Animate.scalar(body, "position.x", from: Double(-w0 / 2), to: Double(-w1 / 2), Springs.bubbleWidth, begin: begin)
        Animate.scalar(body, "bounds.size.height", from: Double(h0), to: Double(h1), Springs.bubbleWidth, begin: begin)
        Animate.scalar(body, "position.y", from: Double(h0 / 2), to: Double(h1 / 2), Springs.bubbleWidth, begin: begin)
        for (kp, a, b) in [("bounds.size.width", w0, w1), ("position.x", -w0 / 2, -w1 / 2), ("bounds.size.height", h0, h1), ("position.y", h0 / 2, h1 / 2)] {
            Animate.scalar(underlay, kp, from: Double(a), to: Double(b), Springs.bubbleWidth, begin: begin)
        }
        Animate.scalar(tail, "position.y", from: Double(h1 / 2 + (h0 - h1) / 2), to: Double(h1 / 2), Springs.bubbleWidth, begin: begin)
        Animate.pulse(bubble, "transform.scale", Springs.bubbleScale, begin: begin)
        let o = Springs.bubbleOpacity
        Animate.scalar(body, "opacity", from: o.from, to: 1, o, begin: begin)
        Animate.scalar(tail, "opacity", from: o.from, to: 1, o, begin: begin)
        // The grey under the translucent bubble belongs to the bubble, not to
        // the field glass: it stays while the glass fill fades (measured at
        // 0256: blue at 0.76 over grey about 70, with the glass fill gone).
        // Once the body is opaque it is covered.
        Animate.scalar(text, "opacity", from: 0, to: 1, Springs.textUnblur, begin: begin)
        Animate.scalar(blurred, "opacity", from: 1, to: 0, Springs.textUnblur, begin: begin)

        // Land: when every component has settled, the cell (same pixels) shows
        // and the morph hides, both on the render server's clock.
        // Land when every element is within 0.1 pt (opacity 0.01) of its final
        // value: then the overlay and the cell show the same pixels.
        let checks: [(SpringElement, Double, Double, Double)] = [
            (Springs.bubbleRight, Double(field.maxX), Double(target.maxX), 0.1),
            (Springs.bubbleCenterY, Double(field.midY), Double(target.midY), 0.1),
            (Springs.bubbleWidth, Double(w0), Double(w1), 0.1),
            (Springs.bubbleScale, 1, 1, 0.1 / Double(max(w1, h1))),
            (o, o.from, 1, 0.01), (Springs.textUnblur, 0, 1, 0.01)]
        var settle = 0.3
        search: while settle < 2.0 {
            for (e, a, b, tol) in checks {
                for k in 0..<12 where abs(e.value(settle + Double(k) / 120, from: a, to: b) - b) > tol { settle += 1.0 / 120; continue search }
            }
            break
        }
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
        let h0 = Double(fieldRect.height), h1 = Double(flyingRect.height)
        let cy = Springs.bubbleCenterY.value(tau, from: Double(fieldRect.midY), to: Double(flyingRect.midY))
        let s = Springs.bubbleScale.value(tau, from: 1, to: 1)
        let h = Springs.bubbleWidth.value(tau, from: h0, to: h1)
        return cy + (h - h1 / 2) * s
    }

    /// A display-scale change during the flight (the window moved to another
    /// screen): re-rasterize at the new scale; the animations keep running.
    func rescale() {
        for l in [holder, bubble, body, text, blurred, tail, underlay] { l.contentsScale = Fixture.renderScale }
        (text.contents, blurred.contents) = MorphBubble.textImages(textLayout, textSize)
    }

    /// A later transcript shift moves the target slot: same additive motion as the row.
    func shift(by dy: Double, _ element: SpringElement, begin: CFTimeInterval) {
        guard abs(dy) > 0.01 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        holder.position.y -= CGFloat(dy)
        CATransaction.commit()
        Animate.scalar(holder, "position.y", from: Double(holder.position.y) + dy, to: Double(holder.position.y), element, begin: begin)
    }

    /// User scroll during the flight (no animation).
    func scroll(by dy: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        holder.position.y -= dy
        CATransaction.commit()
    }

    func remove() { holder.removeFromSuperlayer() }

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
        return UIColor(red: (a.1 + (b.1 - a.1) * f) / 255, green: (a.2 + (b.2 - a.2) * f) / 255, blue: Fixture.gradientBlue / 255, alpha: 1)
    }
}
