import AppKit
import QuartzCore

/// The send morph: the composer's text leaves as an inverted bubble whose four
/// edges each follow a spring fitted to the Messages recording, from the
/// composer field (`ghost`) to the row's slot. Every edge is additive Core
/// Animation components on the flight layers (positions and sizes are sums
/// of edge components), committed once; a second send or a row insert adds
/// components on top (`retarget`), so nothing snaps. Rects are y-down view
/// points; layers are y-up.
final class SendFlight {
    let start: Double
    private(set) var slot: CGRect
    private var top: [MotionComponent], bottom: [MotionComponent]
    private var left: [MotionComponent], right: [MotionComponent]
    private let fill: [MotionComponent], text: [MotionComponent]
    private let committer: MotionCommitter
    let container = CALayer()
    private let shape = CALayer()
    private let body = CALayer()
    private let textLayer = CALayer()
    private let tags = (body: MotionTag(), text: MotionTag(), shape: MotionTag(), container: MotionTag())
    private var hidesAtEnd = false

    init(start t0: Double, ghost: CGRect, slot: CGRect, committer: MotionCommitter) {
        self.start = t0
        self.slot = slot
        self.committer = committer
        // edge starts relative to the send, from springs.json "flight_screen_edges"
        top = [committer.make(start: t0 + 0.0398, delta: ghost.minY - slot.minY, timing: .flightTop)]
        bottom = [committer.make(start: t0 + 0.0477, delta: ghost.maxY - slot.maxY, timing: .flightBottom)]
        right = [committer.make(start: t0 + 0.0187, delta: ghost.maxX - slot.maxX, timing: .flightRight)]
        // the left edge overshoots past the slot and settles back: two springs; the overshoot
        // scales with the bubble width (fitted on a 151 pt bubble: 137 pt)
        let dl = ghost.minX - slot.minX
        let back = 137 * slot.width / 151
        left = [committer.make(start: t0 + 0.011, delta: dl - back, timing: .flightLeftA),
                committer.make(start: t0 + 0.136, delta: back, timing: .flightLeftB)]
        fill = [committer.make(start: t0 + 0.05, delta: -0.38, timing: .flightFade)]
        text = [committer.make(start: t0 + 0.05, delta: -0.65, timing: .flightFade)]
    }

    /// When the flight is over (its row shows).
    var end: Double { start + TranscriptTiming.flightDuration + 0.05 }

    /// The slot moved by `dy` (another event): both vertical edges follow with that event's timing.
    func retarget(dy: CGFloat, at time: Double, timing: TranscriptTiming, slot new: CGRect) {
        top.append(committer.make(start: time, delta: dy, timing: timing))
        bottom.append(committer.make(start: time, delta: dy, timing: timing))
        slot = new
    }

    func makeLayers(text value: String, mentions: [HomeMention], geometry g: TranscriptGeometry,
                    colors: TranscriptColors, scale: CGFloat) {
        for layer in [container, shape, body, textLayer] {
            layer.actions = RowLayer.noActions
            layer.contentsScale = scale
        }
        shape.allowsGroupOpacity = true
        body.backgroundColor = colors.outgoingFill.cgColor
        body.cornerRadius = min(g.bubbleRadius, slot.height / 2)
        body.cornerCurve = .continuous
        body.anchorPoint = CGPoint(x: 1, y: 0)
        // the text rides in the body, pinned to its top-left corner and clipped by it
        body.isGeometryFlipped = true
        body.masksToBounds = true
        textLayer.anchorPoint = .zero
        textLayer.position = .zero
        let size = slot.size
        textLayer.bounds = CGRect(origin: .zero, size: size)
        textLayer.contents = Self.textImage(value, mentions: mentions, size: size, geometry: g, colors: colors, scale: scale)
        shape.addSublayer(body)
        container.addSublayer(shape)
        body.addSublayer(textLayer)
    }

    /// The bubble text alone (the body layer draws the fill), drawn once at send.
    private static func textImage(_ text: String, mentions: [HomeMention], size: CGSize, geometry g: TranscriptGeometry,
                                  colors c: TranscriptColors, scale: CGFloat) -> CGImage? {
        let pw = max(1, Int((size.width * scale).rounded(.up))), ph = max(1, Int((size.height * scale).rounded(.up)))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: g.insetX, dy: g.insetY)
        RowPainter.textBlock(text, mentions: mentions, color: c.outgoingText, in: inner, g: g, ctx)
        return ctx.makeImage()
    }

    /// Sets the model values (the slot) and commits components not yet on the layers.
    func render(now t: Double, viewHeight h: CGFloat, viewWidth w: CGFloat) {
        container.frame = CGRect(x: 0, y: 0, width: w, height: h)
        shape.frame = container.bounds
        body.bounds = CGRect(x: 0, y: 0, width: max(1, slot.width), height: max(1, slot.height))
        body.position = CGPoint(x: slot.maxX, y: h - slot.maxY)
        textLayer.setAffineTransform(.identity)
        // body anchored at its bottom-right: width = R - L, height = B - T
        committer.attach(right, to: body, keyPath: "position.x", scale: 1, now: t, tag: tags.body)
        committer.attach(bottom, to: body, keyPath: "position.y", scale: -1, now: t, tag: tags.body)
        committer.attach(right, to: body, keyPath: "bounds.size.width", scale: 1, now: t, tag: tags.body)
        committer.attach(left, to: body, keyPath: "bounds.size.width", scale: -1, now: t, tag: tags.body)
        committer.attach(bottom, to: body, keyPath: "bounds.size.height", scale: 1, now: t, tag: tags.body)
        committer.attach(top, to: body, keyPath: "bounds.size.height", scale: -1, now: t, tag: tags.body)
        committer.attach(fill, to: shape, keyPath: "opacity", scale: 1, now: t, tag: tags.shape)
        committer.attach(text, to: textLayer, keyPath: "opacity", scale: 1, now: t, tag: tags.text)
        // the text scales with the bubble height: one component per vertical edge spring
        committer.attach(bottom, to: textLayer, keyPath: "transform.scale", scale: 1 / max(1, slot.height), now: t,
                         tag: tags.text)
        committer.attach(top, to: textLayer, keyPath: "transform.scale", scale: -1 / max(1, slot.height), now: t,
                         tag: tags.text)
        // visible for the flight's lifetime, then gone exactly when the row appears
        container.opacity = 0
        guard !hidesAtEnd else { return }
        hidesAtEnd = true
        let visible = committer.make(start: start, delta: 1, timing: .hold(duration: TranscriptTiming.flightDuration))
        committer.attach([visible], to: container, keyPath: "opacity", scale: 1, now: t, tag: tags.container)
    }
}
