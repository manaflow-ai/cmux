import AppKit
import CmuxNextDesign

/// The onboarding's button: a flat pill in theme colors. Primary is the
/// foreground color filled (the one strong element on a page), secondary a
/// faint fill, plain text only. Hover fades in, press is instant.
final class OnboardingButton: NSControl {
    enum Style { case primary, secondary, plain }

    var style: Style { didSet { refreshColors() } }
    var title: String { didSet { label.stringValue = title; invalidateIntrinsicContentSize() } }
    /// A trailing key hint ("↵"), drawn dimmer.
    var keyHint: String? { didSet { hint.stringValue = keyHint ?? ""; hint.isHidden = keyHint == nil; invalidateIntrinsicContentSize() } }
    var onPress: (() -> Void)?
    private let label = OnboardingLabel.make(font: Typography.bodyEmphasized)
    private let hint = OnboardingLabel.make(font: Typography.shortcut)
    private var hovering = false
    private var pressing = false
    private var tracking: NSTrackingArea?

    init(_ title: String, style: Style = .secondary, keyHint: String? = nil, action: (() -> Void)? = nil) {
        self.style = style
        self.title = title
        self.keyHint = keyHint
        onPress = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.stringValue = title
        hint.stringValue = keyHint ?? ""
        hint.isHidden = keyHint == nil
        label.setContentHuggingPriority(.required, for: .horizontal)
        hint.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [label, hint])
        stack.spacing = Metrics.space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: OnboardingMetrics.buttonHeight),
            widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor, constant: Metrics.space6 * 2),
        ])
        // Hug the title unless a container asks for more width.
        let hug = widthAnchor.constraint(equalTo: stack.widthAnchor, constant: Metrics.space6 * 2)
        hug.priority = .hugsInStack
        hug.isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool { didSet { refreshColors() } }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refreshColors(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshColors(animated: true) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        refreshColors()
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        refreshColors()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    func press() {
        guard isEnabled else { return }
        onPress?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func refreshColors(animated: Bool = false) {
        let fill: NSColor
        let text: NSColor
        switch style {
        case .primary:
            fill = pressing ? Palette.textSecondary : (hovering ? Palette.textPrimary.faded(0.88) : Palette.textPrimary)
            text = Palette.textOnPrimary
        case .secondary:
            fill = pressing ? Palette.pressedFill : (hovering ? Palette.selectionFill : Palette.hoverFill)
            text = Palette.textPrimary
        case .plain:
            fill = pressing ? Palette.pressedFill : (hovering ? Palette.hoverFill : .clear)
            text = Palette.textSecondary
        }
        let color = (isEnabled ? fill : fill.faded(0.4)).cgColor
        if animated, let layer { Motion.set(layer, "backgroundColor", to: color, fade: .hover) } else { layer?.backgroundColor = color }
        label.textColor = isEnabled ? text : text.faded(0.45)
        hint.textColor = text.faded(0.55)
    }
}
