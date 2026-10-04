import AppKit

/// The empty Chief conversation's first-run panel: what the Chief is, where
/// it remembers, and one suggested prompt. The suggestion fills the field
/// (`onSuggestion`); it never sends. Hidden once the conversation has a
/// message (`HomeNativeTranscriptView.updateFirstRun`).
final class HomeFirstRunView: NSView {
    let title = NSTextField(wrappingLabelWithString: HomeStrings.firstRunTitle)
    let body = NSTextField(wrappingLabelWithString: HomeStrings.firstRunBody)
    let memory = NSTextField(wrappingLabelWithString: HomeStrings.memoryDeviceOnly)
    let suggestion = NSButton(title: HomeStrings.firstRunSuggestion, target: nil, action: nil)
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
        suggestion.bezelStyle = .glass
        suggestion.target = self
        suggestion.action = #selector(suggest)
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

    @objc private func suggest() { onSuggestion(suggestion.title) }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(primary: NSColor, secondary: NSColor) { // theme-scoped
        title.textColor = primary
        body.textColor = secondary
        memory.textColor = secondary
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
