import AppKit

/// The empty Chief conversation's first-run panel: what the Chief is, where
/// it remembers, and one suggested prompt. The suggestion fills the field
/// (`onSuggestion`); it never sends. Hidden once the conversation has a
/// message (`HomeNativeTranscriptView.updateFirstRun`).
final class HomeFirstRunView: NSView {
    let title = NSTextField(wrappingLabelWithString: HomeStrings.firstRunTitle)
    let body = NSTextField(wrappingLabelWithString: HomeStrings.firstRunBody)
    let memory = NSTextField(wrappingLabelWithString: HomeStrings.memoryDeviceOnly)
    let suggestion = HomeSuggestionChip(title: HomeStrings.firstRunSuggestion)
    private let stack = NSStackView()
    /// Called with the suggested prompt when the user clicks it.
    var onSuggestion: (String) -> Void = { _ in }

    static let maxWidth: CGFloat = 420

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        body.font = .systemFont(ofSize: 13)
        memory.font = .systemFont(ofSize: 12)
        for label in [title, body, memory] {
            label.alignment = .center
            label.isSelectable = false
        }
        suggestion.onClick = { [weak self] in self?.suggest() }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        for view in [title, body, memory, suggestion] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(16, after: memory)
        addSubview(stack)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func suggest() { onSuggestion(suggestion.title) }

    /// Colours from the theme (caller runs inside `performWithTheme`): text
    /// tiers, and the suggestion's raised fill, hover fill and hairline.
    func applyColors(primary: NSColor, secondary: NSColor, fill: NSColor, hover: NSColor, border: NSColor) { // theme-scoped
        title.textColor = primary
        body.textColor = secondary
        memory.textColor = secondary
        suggestion.applyColors(text: primary, fill: fill, hover: hover, border: border)
    }

    override func layout() {
        super.layout()
        let width = min(Self.maxWidth, bounds.width - 48)
        for label in [title, body, memory] { label.preferredMaxLayoutWidth = width }
        let size = stack.fittingSize
        stack.frame = CGRect(x: (bounds.width - width) / 2, y: max(0, (bounds.height - size.height) / 2),
                             width: width, height: size.height)
    }
}

/// The suggested prompt: text on a raised small-radius rect with a
/// hairline, in the theme's colours (never a capsule), taking the hover fill
/// under the pointer. A bezel NSButton draws gray when the window is not key
/// and reads as disabled. Clicks and VoiceOver's press run `onClick`.
final class HomeSuggestionChip: NSView {
    let surface = NSView()
    let label: NSTextField
    var onClick: () -> Void = {}
    var title: String { label.stringValue }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    static let cornerRadius: CGFloat = 8
    private var fill = NSColor.clear
    private var hoverFill = NSColor.clear
    private var isHovered = false { didSet { if isHovered != oldValue { paint() } } }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(text: NSColor, fill: NSColor, hover: NSColor, border: NSColor) { // theme-scoped
        label.textColor = text
        self.fill = fill
        // The hover token is translucent: composite it over the raised fill.
        hoverFill = fill.blended(withFraction: hover.alphaComponent, of: hover.withAlphaComponent(1)) ?? fill
        surface.layer?.borderColor = border.cgColor
        paint()
    }

    private func paint() {
        surface.layer?.backgroundColor = (isHovered ? hoverFill : fill).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: ceil(text.width) + 28, height: 28)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    func performClick(_ sender: Any?) { onClick() }
}
