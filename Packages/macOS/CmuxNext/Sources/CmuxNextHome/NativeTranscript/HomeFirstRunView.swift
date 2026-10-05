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

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(primary: NSColor, secondary: NSColor) { // theme-scoped
        title.textColor = primary
        body.textColor = secondary
        memory.textColor = secondary
        suggestion.label.textColor = primary
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

/// The suggested prompt: text on glass, like the header's name pill. A
/// glass-bezel NSButton draws gray when the window is not key and reads as
/// disabled. Clicks and VoiceOver's press run `onClick`.
final class HomeSuggestionChip: NSView {
    let glass = NSGlassEffectView()
    let label: NSTextField
    var onClick: () -> Void = {}
    var title: String { label.stringValue }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        glass.cornerRadius = 14
        addSubview(glass)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: ceil(text.width) + 28, height: 28)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
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
