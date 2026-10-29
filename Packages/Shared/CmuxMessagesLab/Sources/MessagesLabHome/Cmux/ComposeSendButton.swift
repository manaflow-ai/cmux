import AppKit

/// cmux: the compose field's send button (user, 2026-10-20). It sits in the field's trailing slot,
/// where Messages draws the voice waveform: an empty field shows the waveform, typed text turns
/// it into this button (a spring scale and fade, about 200 ms; none under Reduce Motion). It stays
/// on the bottom-right of the last line while the field grows and scrolls (`ComposeSendSlot`). A
/// click sends exactly as Return does (`onSend`, the same `ChatController.send`).
///
/// Look (plans/cmux-next/send-button/gallery.html, design 1 "Graphite disc", Recommended): a
/// 24 pt disc, near-black with a white arrow on a light theme, light gray with a dark arrow on a
/// dark one; no accent colour. Its layer is the 28 pt hit target around the disc, drawn in the compose
/// bar's one controls view (`ComposeChromeView`), which hit-tests and tracks it.
@MainActor
final class ComposeSendButton {
    /// A click or VoiceOver press on an enabled, shown button.
    var onSend: () -> Void = {}
    /// The view it is drawn in (a layer of `ComposeChromeView`, no view of its own).
    weak var owner: ComposeChromeView? { didSet { element.view = owner } }

    /// The 28 pt hit target, in the owner's coordinates (y down).
    let layer = CALayer()
    private let disc = CALayer()
    private let arrow = CAShapeLayer()
    /// The button for VoiceOver and the accessibility API.
    let element = ComposeChromeElement()
    private(set) var isShown = false
    private(set) var isEnabled = false
    private var isLight = false
    private var hovering = false
    private var pressing = false

    /// The hit target (and the layer's size).
    static let target: CGFloat = ComposeSendSlot.target
    /// The visible disc.
    static let diameter: CGFloat = 24
    /// The scale and opacity the disc grows from and shrinks to.
    static let hiddenScale: CGFloat = 0.55

    init() {
        let none: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
                                        "transform": NSNull(), "opacity": NSNull(), "strokeColor": NSNull(), "path": NSNull(),
                                        "hidden": NSNull(), "contentsScale": NSNull()]
        layer.actions = none
        disc.actions = none
        arrow.actions = none
        layer.bounds = CGRect(x: 0, y: 0, width: Self.target, height: Self.target)
        let inset = (Self.target - Self.diameter) / 2
        disc.frame = CGRect(x: inset, y: inset, width: Self.diameter, height: Self.diameter)
        disc.cornerRadius = Self.diameter / 2
        arrow.frame = disc.bounds
        arrow.fillColor = nil
        arrow.lineWidth = 1.9
        arrow.lineCap = .round
        arrow.lineJoin = .round
        arrow.path = Self.arrowPath(in: disc.bounds)
        disc.addSublayer(arrow)
        layer.addSublayer(disc)
        disc.opacity = 0
        disc.transform = CATransform3DMakeScale(Self.hiddenScale, Self.hiddenScale, 1)
        element.setAccessibilityIdentifier("cmux.home.composer.send")
        element.setAccessibilityLabel(CmuxStrings.send)
        element.setAccessibilityEnabled(false)
        element.onPress = { [weak self] in self?.press() ?? false }
        applyColors()
    }

    /// The hit target in the owner's coordinates. A move changes the layer's position only (no
    /// layout, no display); the owner's cursor, tool tip and hover rects follow.
    var frame: CGRect {
        get { layer.frame }
        set {
            guard newValue != layer.frame else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.frame = newValue
            CATransaction.commit()
            element.frameInView = newValue
            owner?.controlsChanged(visibility: false)
        }
    }
    /// The visible disc in the owner's coordinates (the focus ring's shape).
    var discFrame: CGRect {
        let inset = (Self.target - Self.diameter) / 2
        return frame.insetBy(dx: inset, dy: inset)
    }

    /// The window's scale: the arrow's shape rasterizes at it.
    func rescale(_ s: CGFloat) {
        for l in [layer, disc, arrow] where l.contentsScale != s { l.contentsScale = s }
    }

    /// The up arrow, 12 pt, centred in the disc (flipped: y down).
    private static func arrowPath(in r: CGRect) -> CGPath {
        let p = CGMutablePath(), c = CGPoint(x: r.midX, y: r.midY), s: CGFloat = 12 / 12
        p.move(to: CGPoint(x: c.x, y: c.y + 4.5 * s))
        p.addLine(to: CGPoint(x: c.x, y: c.y - 4.2 * s))
        p.move(to: CGPoint(x: c.x - 3.8 * s, y: c.y - 0.6 * s))
        p.addLine(to: CGPoint(x: c.x, y: c.y - 4.4 * s))
        p.addLine(to: CGPoint(x: c.x + 3.8 * s, y: c.y - 0.6 * s))
        return p
    }

    // MARK: State

    /// Shows or hides the button and sets whether a click sends. `animated` is false under Reduce
    /// Motion and for programmatic placement (a conversation switch).
    func set(shown: Bool, enabled: Bool, animated: Bool) {
        let enabledChanged = enabled != isEnabled
        isEnabled = enabled
        if enabledChanged { element.setAccessibilityEnabled(enabled) }
        if shown != isShown {
            isShown = shown
            if !shown { pressing = false; hovering = false }
            transition(animated: animated)
            owner?.controlsChanged(visibility: true)
        }
        if enabledChanged { applyColors() }
    }

    /// The light or dark theme (Fixture.lightAppearance).
    func setLight(_ light: Bool) {
        guard light != isLight else { return }
        isLight = light
        applyColors()
    }

    private func transition(animated: Bool) {
        let toScale = isShown ? 1 : Self.hiddenScale
        let toOpacity: Float = isShown ? (isEnabled ? 1 : Self.disabledOpacity) : 0
        // The disc only ever has a scale transform, so its x scale is m11 (no KVC key path read).
        let fromScale = disc.presentation().map { $0.transform.m11 } ?? (isShown ? Self.hiddenScale : 1)
        let fromOpacity = disc.presentation()?.opacity ?? disc.opacity
        disc.removeAnimation(forKey: "show")
        disc.removeAnimation(forKey: "fade")
        disc.transform = CATransform3DMakeScale(toScale, toScale, 1)
        disc.opacity = toOpacity
        guard animated else { return }
        if isShown {
            // A soft spring (about 200 ms to settle, a 2-3 % overshoot), the disc grows from the waveform's spot.
            let s = CASpringAnimation(keyPath: "transform.scale")
            s.mass = 1; s.stiffness = 520; s.damping = 30; s.initialVelocity = 0
            s.fromValue = fromScale; s.toValue = toScale
            s.duration = min(0.35, s.settlingDuration)
            disc.add(s, forKey: "show")
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = fromOpacity; f.toValue = toOpacity
            f.duration = 0.12
            f.timingFunction = CAMediaTimingFunction(name: .easeOut)
            disc.add(f, forKey: "fade")
        } else {
            let group = CAAnimationGroup()
            let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = fromScale; s.toValue = toScale
            let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = fromOpacity; f.toValue = toOpacity
            group.animations = [s, f]
            group.duration = 0.14
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            disc.add(group, forKey: "show")
        }
    }

    static let disabledOpacity: Float = 0.38

    private func applyColors() {
        // Graphite: no accent; the contrast of the arrow on the disc is above 12:1 in both themes.
        let fill: NSColor, ink: NSColor
        if isLight {
            fill = hovering && isEnabled ? NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
                : NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1)
            ink = .white
        } else {
            fill = hovering && isEnabled ? NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1)
                : NSColor(srgbRed: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255, alpha: 1)
            ink = NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        disc.backgroundColor = fill.cgColor
        arrow.strokeColor = ink.cgColor
        // The model values are the resting ones; a running show or fade animation ends on them.
        if isShown {
            disc.opacity = isEnabled ? 1 : Self.disabledOpacity
            let pressed: CGFloat = pressing && isEnabled && disc.animation(forKey: "show") == nil ? 0.88 : 1
            disc.transform = CATransform3DMakeScale(pressed, pressed, 1)
        }
        CATransaction.commit()
    }

    // MARK: Pointer (the owner tracks it: ComposeChromeView)

    /// The pointer is over the button (its owner's hover area).
    func setHovering(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        applyColors()
    }

    /// A press is held on the button with the pointer over it.
    func setPressing(_ on: Bool) {
        let on = on && isShown
        guard on != pressing else { return }
        pressing = on
        applyColors()
    }

    /// Sends when shown and enabled (a click, VoiceOver, the keyboard).
    @discardableResult func press() -> Bool {
        guard isShown, isEnabled else { return false }
        onSend()
        return true
    }
}
