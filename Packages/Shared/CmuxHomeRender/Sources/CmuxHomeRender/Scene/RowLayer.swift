import CoreGraphics
import QuartzCore

/// One transcript row as plain Core Animation layers: the content bitmap,
/// the outgoing gradient fill under it, the receipt cross-fade and typing
/// dots. `layer` carries the row's position springs; `content` its fades.
@MainActor
final class RowLayer {
    let layer = CALayer()
    let content = CALayer()
    private(set) var spec: RowSpec?
    private(set) var key = ""
    /// Ledger entries already added to this row's layers.
    var applied = Set<Int>()

    private let fillContainer = CALayer()
    private let fillGradient = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    let bitmap = CALayer()
    let typingContainer = CALayer()
    private var dots: [CALayer] = []
    let receiptOld = CALayer()
    /// A media bubble: the placeholder fill and the picture (or the video
    /// player) under the bubble mask, then the play badge.
    let mediaContainer = CALayer()
    private let mediaMask = CAShapeLayer()
    let mediaImage = CALayer()
    let playBadge = CALayer()
    /// Upload progress over a media bubble or a file chip's icon.
    let progressRing = CAShapeLayer()
    private let progressTrack = CAShapeLayer()
    /// Content hash of the media this row shows (nil: not a media row).
    private(set) var mediaHash: String?
    private var metrics = Metrics(width: 0)
    private var viewportHeight: CGFloat = 0
    private var paletteGeneration = -1

    static let noActions: [String: CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "path": NSNull(), "hidden": NSNull(),
        "opacity": NSNull(), "transform": NSNull(), "zPosition": NSNull(), "backgroundColor": NSNull(),
        "colors": NSNull(), "locations": NSNull(), "sublayerTransform": NSNull(), "anchorPoint": NSNull(),
        "frame": NSNull(), "mask": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    init() {
        for l in [layer, content, fillContainer, fillGradient, fillMask, bitmap, typingContainer, receiptOld,
                  mediaContainer, mediaMask, mediaImage, playBadge, progressRing, progressTrack] {
            l.actions = RowLayer.noActions
            l.contentsScale = Canvas.scale
        }
        fillContainer.addSublayer(fillGradient)
        fillContainer.mask = fillMask
        layer.addSublayer(content)
        content.addSublayer(fillContainer)
        mediaContainer.mask = mediaMask
        mediaContainer.addSublayer(mediaImage)
        mediaImage.contentsGravity = .resizeAspectFill
        mediaImage.masksToBounds = true
        mediaContainer.isHidden = true
        playBadge.isHidden = true
        content.addSublayer(mediaContainer)
        content.addSublayer(bitmap)
        content.addSublayer(playBadge)
        for ring in [progressTrack, progressRing] {
            ring.fillColor = nil
            ring.lineWidth = 3
            ring.lineCap = .round
            ring.isHidden = true
            content.addSublayer(ring)
        }
        progressTrack.strokeColor = CGColor(gray: 0, alpha: 0.35)
        progressRing.strokeColor = CGColor(gray: 1, alpha: 0.95)
        typingContainer.isHidden = true
        typingContainer.anchorPoint = CGPoint(x: 0, y: 1)
        let b = RowArt.typingBubble
        typingContainer.bounds = CGRect(x: 0, y: 0, width: RowArt.typingWidth, height: b.maxY + 8)
        typingContainer.position = CGPoint(x: 0, y: b.maxY + 8)
        for i in 0..<3 {
            let dot = CALayer()
            let highlight = CALayer()
            for l in [dot, highlight] {
                l.actions = RowLayer.noActions
                l.cornerRadius = 3.25
            }
            highlight.opacity = 0
            dot.addSublayer(highlight)
            let c = RowArt.typingDotCenter(i)
            dot.frame = CGRect(x: c.x - 3.25, y: c.y - 3.25, width: 6.5, height: 6.5)
            highlight.frame = dot.bounds
            typingContainer.addSublayer(dot)
            dots.append(dot)
        }
        content.addSublayer(typingContainer)
    }

    /// Back to the pool: no animations, no row.
    func prepareForReuse() {
        clearAnimations()
        applied = []
        key = ""
        setPlayer(nil)
    }

    private func clearAnimations() {
        for l in [layer, content, fillContainer, bitmap, typingContainer, receiptOld] { l.removeAllAnimations() }
        dots.forEach { $0.sublayers?.first?.removeAllAnimations() }
    }

    /// Shows `spec` laid out for `metrics`. The bitmap comes from the content
    /// cache, so a row whose content did not change is not redrawn; a new
    /// bitmap is drawn off the main actor and installed when it is ready.
    func configure(_ spec: RowSpec, metrics: Metrics, bitmaps: RowBitmaps, viewportHeight: CGFloat) {
        if key != spec.key { clearAnimations(); applied = []; key = spec.key }
        let paletteChanged = paletteGeneration != bitmaps.paletteGeneration
        guard paletteChanged || self.spec != spec || self.metrics != metrics || self.viewportHeight != viewportHeight else { return }
        if paletteChanged {
            applyPalette(bitmaps.palette)
            paletteGeneration = bitmaps.paletteGeneration
            bitmap.contentsScale = bitmaps.scale
            receiptOld.contentsScale = bitmaps.scale
        }
        self.spec = spec
        self.metrics = metrics
        self.viewportHeight = viewportHeight
        let frame = RowArt.frame(spec, metrics: metrics)
        bitmap.frame = frame
        // A miss draws off the main actor; the result lands here if the row still shows this spec.
        let generation = paletteGeneration
        bitmap.contents = bitmaps.image(for: spec, size: frame.size) { [weak self] image in
            guard let self, self.spec == spec, self.paletteGeneration == generation else { return }
            self.bitmap.contents = image
        }
        let typing = if case .typing = spec.kind { true } else { false }
        typingContainer.isHidden = !typing
        if typing {
            if bitmap.superlayer !== typingContainer { typingContainer.insertSublayer(bitmap, at: 0) }
        } else if bitmap.superlayer !== content {
            content.insertSublayer(bitmap, above: mediaContainer)
        }
        configureFill(spec)
        configureMedia(spec, palette: bitmaps.palette, scale: bitmaps.scale)
        receiptOld.contents = nil
    }

    private func applyPalette(_ palette: HomePalette) {
        fillGradient.colors = palette.outgoingGradient.map(\.color.cgColor)
        fillGradient.locations = palette.outgoingGradient.map { NSNumber(value: Double($0.location)) }
        for dot in dots {
            dot.backgroundColor = palette.typingDot.cgColor
            dot.sublayers?.first?.backgroundColor = palette.typingDotHighlight.cgColor
        }
    }

    private func configureFill(_ spec: RowSpec) {
        guard let p = spec.partRow, p.outgoing, p.media == nil else {
            fillContainer.isHidden = true
            return
        }
        fillContainer.isHidden = false
        let body = RowArt.bodyRect(spec, metrics: metrics)
        fillContainer.frame = CGRect(x: 0, y: 0, width: metrics.width, height: spec.height + 2 * Style.rowMargin)
        fillMask.frame = body
        fillMask.path = BubblePath.make(body: CGRect(origin: .zero, size: body.size), outgoing: true, tail: p.tail)
        fillGradient.frame = CGRect(x: 0, y: -windowY, width: metrics.width, height: viewportHeight)
    }

    /// Frames and mask of a media bubble; other rows hide the media layers.
    /// The picture itself arrives later (`showMedia`) and changes no frame.
    private func configureMedia(_ spec: RowSpec, palette: HomePalette, scale: CGFloat) {
        guard let p = spec.partRow, let media = p.media else {
            mediaContainer.isHidden = true
            playBadge.isHidden = true
            mediaImage.contents = nil
            mediaHash = nil
            return
        }
        let body = RowArt.bodyRect(spec, metrics: metrics)
        mediaContainer.isHidden = false
        mediaContainer.frame = CGRect(x: 0, y: 0, width: metrics.width, height: spec.height + 2 * Style.rowMargin)
        mediaMask.frame = mediaContainer.bounds
        mediaMask.path = BubblePath.make(body: body, outgoing: p.outgoing, tail: p.tail)
        // The picture reaches under the tail on the sender's side.
        let tail: CGFloat = p.tail ? 6 : 0
        mediaImage.frame = CGRect(x: p.outgoing ? body.minX : body.minX - tail, y: body.minY,
                                  width: body.width + tail, height: body.height + BubblePath.tailDrop)
        mediaImage.backgroundColor = palette.incomingBubble.cgColor
        if mediaHash != media.ref.hash { mediaImage.contents = nil }
        mediaHash = media.ref.hash
        let d = min(AttachmentDrawing.playDiameter, min(body.width, body.height) - 8)
        playBadge.frame = CGRect(x: body.midX - d / 2, y: body.midY - d / 2, width: d, height: d)
        if playBadge.contents == nil || playBadge.contentsScale != scale {
            playBadge.contentsScale = scale
            playBadge.contents = AttachmentDrawing.playBadge(scale: scale)
        }
    }

    /// Upload progress (0...1) as a ring centred on `center`; nil hides it.
    func showProgress(_ value: Double?, center: CGPoint, diameter: CGFloat) {
        guard let value else {
            progressRing.isHidden = true
            progressTrack.isHidden = true
            return
        }
        let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: diameter / 2, y: diameter / 2), radius: diameter / 2 - 1.5, startAngle: -.pi / 2,
                    endAngle: 1.5 * .pi, clockwise: false)
        for ring in [progressTrack, progressRing] {
            ring.frame = rect
            ring.path = path
            ring.isHidden = false
        }
        progressRing.strokeEnd = CGFloat(max(0, min(1, value)))
    }

    /// The bubble's picture (nil keeps the placeholder).
    func showMedia(_ image: CGImage?) {
        mediaImage.contents = image
    }

    /// The play badge shows over a video's poster and while paused.
    func showPlayBadge(_ visible: Bool) {
        playBadge.isHidden = !visible
    }

    /// The video player inside the bubble (nil removes it).
    func setPlayer(_ player: CALayer?) {
        let current = mediaImage.sublayers ?? []
        for l in current where l !== player { l.removeFromSuperlayer() }
        guard let player else { return }
        player.frame = mediaImage.bounds
        if player.superlayer !== mediaImage { mediaImage.addSublayer(player) }
    }

    var hasPlayer: Bool { !(mediaImage.sublayers ?? []).isEmpty }

    /// Viewport y of the row's top: the outgoing fill shades with it.
    var windowY: CGFloat = 0 {
        didSet {
            guard windowY != oldValue, !fillContainer.isHidden else { return }
            fillGradient.frame.origin.y = -windowY
        }
    }

    /// The previous receipt, drawn so it can fade out over the new one.
    func setPreviousReceipt(_ image: CGImage?, frame: CGRect) {
        receiptOld.frame = frame
        if receiptOld.superlayer == nil { content.insertSublayer(receiptOld, above: bitmap) }
        receiptOld.contents = image
        receiptOld.opacity = Animate.hiddenOpacity
    }

    var hasTypingDots: Bool { dots.first?.sublayers?.first?.animation(forKey: "dots") != nil }

    func stopTypingDots() {
        dots.forEach { $0.sublayers?.first?.removeAnimation(forKey: "dots") }
    }

    func startTypingDots(begin: CFTimeInterval) {
        for (i, dot) in dots.enumerated() {
            guard let highlight = dot.sublayers?.first else { continue }
            Animate.typingDot(highlight, index: i, begin: begin)
        }
    }
}
