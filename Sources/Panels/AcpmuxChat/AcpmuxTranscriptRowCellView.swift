import AppKit

/// A reusable transcript cell: an optional bubble or card surface plus selectable text,
/// with a timestamp that fades in on hover.
final class AcpmuxTranscriptRowCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("acpmuxChat.row")

    private let surfaceLayer = CAShapeLayer()
    private let textView = AcpmuxTranscriptTextView()
    private let timestampLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private let retryButton = NSButton()
    var onRetry: ((String) -> Void)?
    private(set) var rowID: String?
    private(set) var handlesToggle = false
    var onToggle: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layer?.addSublayer(surfaceLayer)
        addSubview(textView)
        timestampLabel.alphaValue = 0
        timestampLabel.font = .systemFont(ofSize: 10.5)
        addSubview(timestampLabel)
        retryButton.isBordered = false
        retryButton.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: String(localized: "acpmuxChat.message.notDelivered", defaultValue: "Not delivered")
        )
        retryButton.imageScaling = .scaleProportionallyUpOrDown
        retryButton.toolTip = String(localized: "acpmuxChat.message.retry", defaultValue: "Not delivered. Click to send again.")
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.isHidden = true
        addSubview(retryButton)
    }

    @objc private func retryPressed() {
        guard let rowID else { return }
        onRetry?(rowID)
    }

    /// The bubble's outline, for morphs that start from this row.
    var surfacePath: CGPath? { surfaceLayer.path }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(rowID: String, layout: AcpmuxRowLayout, theme: AcpmuxChatTheme, hidden: Bool, reduceMotion: Bool = false) {
        let sameRow = self.rowID == rowID
        let previousPath = surfaceLayer.presentation()?.path ?? surfaceLayer.path
        self.rowID = rowID
        handlesToggle = layout.isToggleable
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch layout.surface {
        case .userBubble: surfaceLayer.fillColor = theme.userBubble.cgColor
        case .assistantBubble, .typing: surfaceLayer.fillColor = theme.assistantBubble.cgColor
        case .card: surfaceLayer.fillColor = theme.surface.cgColor
        case .none: break
        }
        surfaceLayer.path = layout.surfacePath
        if sameRow, !reduceMotion, let previousPath, let newPath = layout.surfacePath, previousPath != newPath {
            // The same bubble changed shape (streaming growth, or growing out of the typing
            // bubble): tween from what is on screen now, replacing any older shape animation
            // so a stale target never pins the bubble to an old size.
            surfaceLayer.removeAnimation(forKey: "acpmuxChat.fromTyping")
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = previousPath
            grow.toValue = newPath
            grow.duration = 0.12
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            surfaceLayer.add(grow, forKey: "acpmuxChat.grow")
            clipText(to: grow, finalFrame: layout.textFrame)
        }
        surfaceLayer.frame = bounds
        CATransaction.commit()
        textView.apply(layout.text, frame: layout.textFrame)
        alphaValue = hidden ? 0 : (layout.dimmed ? 0.72 : 1)
        timestampLabel.stringValue = layout.timestamp ?? ""
        timestampLabel.textColor = theme.tertiaryText
        timestampLabel.sizeToFit()
        let stampY = layout.surfaceFrame.maxY - timestampLabel.frame.height
        if layout.surface == .userBubble {
            timestampLabel.frame.origin = CGPoint(x: max(4, layout.surfaceFrame.minX - timestampLabel.frame.width - 10), y: stampY)
        } else {
            timestampLabel.frame.origin = CGPoint(
                x: min(bounds.width - timestampLabel.frame.width - 4, layout.surfaceFrame.maxX + 10),
                y: stampY
            )
        }
        timestampLabel.isHidden = layout.timestamp == nil || (layout.surface != .userBubble && layout.surface != .assistantBubble)
        retryButton.isHidden = !layout.showsRetry
        if layout.showsRetry {
            retryButton.contentTintColor = theme.danger
            retryButton.frame = CGRect(x: layout.surfaceFrame.minX - 28, y: layout.surfaceFrame.midY - 11, width: 22, height: 22)
            timestampLabel.frame.origin.x = retryButton.frame.minX - timestampLabel.frame.width - 6
        }
    }

    /// Grows this assistant bubble out of the typing indicator that occupied its slot, so
    /// the first streamed text does not pop in.
    func animateFromTyping(_ typingPath: CGPath?, reduceMotion: Bool) {
        guard !reduceMotion, let typingPath, let finalPath = surfaceLayer.path else { return }
        let grow = CASpringAnimation(keyPath: "path")
        grow.fromValue = typingPath
        grow.toValue = finalPath
        Self.applyResponse(grow)
        surfaceLayer.add(grow, forKey: "acpmuxChat.fromTyping")
        clipText(to: grow, finalFrame: textView.frame)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.beginTime = CACurrentMediaTime() + 0.06
        fade.fillMode = .backwards
        textView.layer?.add(fade, forKey: "acpmuxChat.fromTyping.text")
    }

    /// Masks the text with the bubble outline for the duration of a shape animation, so
    /// text laid out at the final width never spills past a bubble that is still growing.
    private func clipText(to animation: CABasicAnimation, finalFrame: CGRect) {
        guard let textLayer = textView.layer,
              let from = animation.fromValue as! CGPath?, let to = animation.toValue as! CGPath? else { return }
        // The mask lives in the text view's coordinates; the cell is flipped like the text view.
        var shift = CGAffineTransform(translationX: -finalFrame.minX, y: -finalFrame.minY)
        let mask = CAShapeLayer()
        // After the animation the presentation falls back to this model path, which covers
        // everything: the mask then clips nothing and needs no completion callback.
        mask.path = CGPath(rect: textLayer.bounds.insetBy(dx: -10_000, dy: -10_000), transform: nil)
        mask.frame = textLayer.bounds
        let maskAnimation = animation.copy() as! CABasicAnimation
        maskAnimation.fromValue = from.copy(using: &shift)
        maskAnimation.toValue = to.copy(using: &shift)
        textLayer.mask = mask
        mask.add(maskAnimation, forKey: "acpmuxChat.clip")
    }

    /// Scales the bubble in from 0.9 around its tail and fades it in.
    func animateArrival(anchor: CGPoint, reduceMotion: Bool) {
        guard !reduceMotion, let layer else { return }
        // AppKit layers anchor at their origin; scale about `anchor` by conjugating the scale.
        var scale = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        scale = CATransform3DScale(scale, 0.9, 0.9, 1)
        scale = CATransform3DTranslate(scale, -anchor.x, -anchor.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: scale)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        Self.applyResponse(spring)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = layer.opacity
        fade.duration = 0.18
        layer.add(spring, forKey: "acpmuxChat.arrive.scale")
        layer.add(fade, forKey: "acpmuxChat.arrive.fade")
    }

    /// A spring with a 0.35 s response and 0.8 damping ratio, the Messages feel.
    static func applyResponse(_ spring: CASpringAnimation, response: Double = 0.35, dampingRatio: Double = 0.8) {
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 2 * dampingRatio * sqrt(spring.stiffness)
        spring.duration = spring.settlingDuration
    }

    override func layout() {
        super.layout()
        surfaceLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            timestampLabel.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            timestampLabel.animator().alphaValue = 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard handlesToggle, let rowID else {
            super.mouseDown(with: event)
            return
        }
        onToggle?(rowID)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.removeAllAnimations()
        timestampLabel.alphaValue = 0
        textView.layer?.removeAllAnimations()
        surfaceLayer.removeAllAnimations()
        onToggle = nil
        onRetry = nil
    }
}
