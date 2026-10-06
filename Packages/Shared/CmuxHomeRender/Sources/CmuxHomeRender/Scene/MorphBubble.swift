import CoreGraphics
import QuartzCore

/// The send morph: the compose field turns into the new bubble.
///
/// Layers (viewport coordinates):
/// - `holder`: full viewport; carries later transcript shifts (position.y).
/// - `bubble`: anchored at its right edge and vertical center. Animated:
///   right edge (position.x), center (position.y), a scale pulse.
/// - `body`: the rounded body, frame (-w, 0, w, h) in `bubble`, so a width
///   change moves only its left edge. It clips the text.
/// - `text` / `blurred`: the bubble's text; the blurred copy fades out as
///   the sharp text fades in.
/// - `tail`: fixed at the right-bottom corner.
/// The row underneath stays hidden until `landTime`, then shows the same pixels.
///
/// An attachment flies the same way from its draft thumbnail (`origin`):
/// a file chip as its chip, an image or video as its picture, which then
/// scales with the body (aspect fill) instead of being clipped by it.
@MainActor
final class MorphBubble {
    /// What lands: the sharp content at the target size, the body fill and
    /// whether the face follows the body's size (media) or stays put (text).
    struct Face {
        var image: CGImage?
        /// Nil: the outgoing colour at the target's viewport position.
        var fill: CGColor?
        var tail: Bool
        var scalesWithBody: Bool
    }

    let key: String
    /// Where it starts and lands (viewport points).
    let origin: CGRect
    let target: CGRect
    let holder = CALayer()
    private let bubble = CALayer()
    private let body = CALayer()
    private let text = CALayer()
    private let blurred = CALayer()
    private let tail = CAShapeLayer()
    private let underlay = CALayer()
    let landTime: CFTimeInterval

    init(key: String, in parent: CALayer, viewport: CGRect, from field: CGRect, to target: CGRect, face: Face,
         palette: HomePalette, motion: MotionPolicy, begin: CFTimeInterval) {
        self.key = key
        origin = field
        self.target = target
        for l in [holder, bubble, body, text, blurred, tail, underlay] {
            l.actions = RowLayer.noActions
            l.contentsScale = Canvas.scale
        }
        holder.frame = viewport
        parent.addSublayer(holder)

        let color = face.fill ?? palette.outgoing(at: viewport.height > 0 ? target.midY / viewport.height : 1).cgColor
        let w1 = target.width, h1 = target.height
        bubble.anchorPoint = CGPoint(x: 1, y: 0.5)
        bubble.bounds = CGRect(x: -w1, y: 0, width: w1, height: h1)
        bubble.position = CGPoint(x: target.maxX, y: target.midY)
        holder.addSublayer(bubble)
        body.backgroundColor = color
        body.cornerRadius = Style.bubbleRadius
        body.masksToBounds = true
        body.bounds = CGRect(x: 0, y: 0, width: w1, height: h1)
        body.position = CGPoint(x: -w1 / 2, y: h1 / 2)
        // While translucent, the bubble shows the field's glass under it.
        underlay.backgroundColor = palette.morphUnderlay.cgColor
        underlay.cornerRadius = Style.bubbleRadius
        underlay.bounds = body.bounds
        underlay.position = body.position
        bubble.addSublayer(underlay)
        bubble.addSublayer(body)
        var shift = CGAffineTransform(translationX: 0, y: h1)
        tail.path = BubblePath.tail().copy(using: &shift)
        tail.fillColor = color
        tail.frame = CGRect(x: -w1, y: 0, width: w1, height: h1)
        tail.bounds = CGRect(x: -w1, y: 0, width: w1, height: h1)
        tail.isHidden = !face.tail
        bubble.addSublayer(tail)
        let size = target.size
        let image = face.image
        text.contents = image
        text.frame = CGRect(origin: .zero, size: size)
        body.addSublayer(text)
        // Blur without Core Image: the text drawn at 1/6 scale and magnified
        // with linear filtering (about a 5 px box blur at 2x).
        if let image {
            blurred.contents = Canvas.image(size: size, scale: Canvas.scale / 6) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: size))
                ctx.restoreGState()
            }
        }
        blurred.magnificationFilter = .linear
        if face.scalesWithBody {
            text.contentsGravity = .resizeAspectFill
            blurred.contentsGravity = .resizeAspectFill
        }
        blurred.frame = text.frame
        body.addSublayer(blurred)
        blurred.opacity = Animate.hiddenOpacity

        let w0 = field.width, h0 = field.height
        let right = motion(HomeMotion.bubbleRight), centerY = motion(HomeMotion.bubbleCenterY)
        let width = motion(HomeMotion.bubbleWidth), scale = motion(HomeMotion.bubbleScale)
        let opacity = motion(HomeMotion.bubbleOpacity), unblur = motion(HomeMotion.textUnblur)
        Animate.scalar(bubble, "position.x", from: Double(field.maxX), to: Double(target.maxX), right, begin: begin)
        Animate.scalar(bubble, "position.y", from: Double(field.midY), to: Double(target.midY), centerY, begin: begin)
        for layer in [body, underlay] {
            for (keyPath, a, b) in [("bounds.size.width", w0, w1), ("position.x", -w0 / 2, -w1 / 2),
                                    ("bounds.size.height", h0, h1), ("position.y", h0 / 2, h1 / 2)] {
                Animate.scalar(layer, keyPath, from: Double(a), to: Double(b), width, begin: begin)
            }
        }
        if face.scalesWithBody {
            for layer in [text, blurred] {
                for (keyPath, a, b) in [("bounds.size.width", w0, w1), ("position.x", w0 / 2, w1 / 2),
                                        ("bounds.size.height", h0, h1), ("position.y", h0 / 2, h1 / 2)] {
                    Animate.scalar(layer, keyPath, from: Double(a), to: Double(b), width, begin: begin)
                }
            }
        }
        Animate.scalar(tail, "position.y", from: Double(h1 / 2 + (h0 - h1) / 2), to: Double(h1 / 2), width, begin: begin)
        Animate.pulse(bubble, "transform.scale", scale, begin: begin)
        Animate.scalar(body, "opacity", from: opacity.from, to: 1, opacity, begin: begin)
        Animate.scalar(tail, "opacity", from: opacity.from, to: 1, opacity, begin: begin)
        Animate.sampledPulse(underlay, "opacity", motion(HomeMotion.fieldOpacity), base: 1, begin: begin)
        Animate.scalar(text, "opacity", from: 0, to: 1, unblur, begin: begin)
        Animate.scalar(blurred, "opacity", from: 1, to: 0, unblur, begin: begin)

        // Land when every element stays within tolerance of its final value
        // for 0.1 s: then the overlay and the row show the same pixels.
        let checks: [(SpringElement, Double, Double, Double)] = [
            (right, Double(field.maxX), Double(target.maxX), HomeMotion.landTolerance),
            (centerY, Double(field.midY), Double(target.midY), HomeMotion.landTolerance),
            (width, Double(w0), Double(w1), HomeMotion.landTolerance),
            (scale, 1, 1, HomeMotion.landTolerance / Double(max(w1, h1, 1))),
            (opacity, opacity.from, 1, HomeMotion.landOpacityTolerance),
            (unblur, 0, 1, HomeMotion.landOpacityTolerance),
        ]
        landTime = begin + Self.settleTime(checks)
    }

    /// The first time after which every check stays within tolerance for 12 frames at 120 Hz.
    static func settleTime(_ checks: [(SpringElement, Double, Double, Double)]) -> Double {
        let frame = 1.0 / 120
        var t = 0.3
        search: while t < 2.0 {
            for (e, a, b, tolerance) in checks {
                for k in 0..<12 where abs(e.value(t + Double(k) * frame, from: a, to: b) - b) > tolerance {
                    t += frame
                    continue search
                }
            }
            break
        }
        return t
    }

    /// A later transcript shift moves the target slot: same additive motion as the row.
    func shift(by dy: Double, _ element: SpringElement, begin: CFTimeInterval) {
        guard abs(dy) > 0.01 else { return }
        holder.position.y -= CGFloat(dy)
        Animate.scalar(holder, "position.y", from: Double(holder.position.y) + dy, to: Double(holder.position.y), element, begin: begin)
    }

    /// User scroll during the flight (no animation).
    func scroll(by dy: CGFloat) { holder.position.y -= dy }

    func remove() { holder.removeFromSuperlayer() }
}
