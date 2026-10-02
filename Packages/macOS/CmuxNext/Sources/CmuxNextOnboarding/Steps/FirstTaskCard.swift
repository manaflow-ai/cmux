import AppKit
import CmuxNextDesign

/// One task to try: a symbol, a title and a line, in a fixed-size card
/// whose fill steps from rest to hover to pressed (theme tokens, Motion's
/// hover fade) and takes the system focus ring. A click anywhere in the
/// card picks it; nothing moves.
final class FirstTaskCard: ThemedView {
    private let onPick: () -> Void
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(symbol: String, title: String, detail: String, onPick: @escaping () -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        cornerRadius = 12
        fill = { [weak self] in self?.currentFill }
        border = { Palette.separator }
        toolTip = detail
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = Palette.textPrimary
        let titleLabel = OnboardingLabel.make(title, font: .systemFont(ofSize: 13, weight: .semibold), lines: 2)
        let detailLabel = OnboardingLabel.make(detail, font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
        for view in [icon, titleLabel, detailLabel] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 120),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var currentFill: NSColor {
        if pressed { return Palette.pressedFill }
        return hovered ? Palette.hoverFill : .clear
    }

    private func refresh() {
        guard let layer else { return }
        Motion.set(layer, "backgroundColor", to: currentFill.cgColor, fade: .hover)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        refresh()
        if inside { onPick() }
    }

    // Keyboard: Tab reaches the card (system focus ring), Space or Return picks it.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r": onPick()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPick()
        return true
    }
}
