import AppKit

/// The compose field: a Liquid Glass capsule holding a real NSTextView
/// (TextKit 2: IME, undo, spell checking, services). Return sends,
/// Option- or Shift-Return inserts a newline; marked text owns Return.
final class HomeFieldView: NSView {
    let glass = NSGlassEffectView()
    let textView = HomeFieldTextView(usingTextLayoutManager: true)
    private let placeholder = NSTextField(labelWithString: "")
    /// Reports the new height after every edit (the host relayouts).
    var onHeightChange: () -> Void = {}
    var onSend: () -> Void = {}

    static let lineHeight: CGFloat = 16
    static let maxLines = 8
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 7

    static func height(lines: Int) -> CGFloat { 30 + lineHeight * CGFloat(lines - 1) + (lines >= 2 ? 1 : 0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = 15
        addSubview(glass)
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        textView.font = font
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.writingToolsBehavior = .limited
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.onSend = { [weak self] in self?.onSend() }
        textView.onChange = { [weak self] in self?.textChanged() }
        textView.setAccessibilityLabel(HomeStrings.messagePlaceholder)
        placeholder.stringValue = HomeStrings.messagePlaceholder
        placeholder.font = font
        placeholder.textColor = .placeholderTextColor
        glass.contentView = textView
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Lines the draft needs at the current width (1...maxLines).
    var lines: Int {
        guard let manager = textView.textLayoutManager else { return 1 }
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer.height
        let n = Int((max(used, Self.lineHeight) / Self.lineHeight).rounded())
        return min(Self.maxLines, max(1, n))
    }

    var preferredHeight: CGFloat { Self.height(lines: lines) }

    var text: String {
        get { textView.string }
        set { textView.string = newValue; textChanged() }
    }

    private func textChanged() {
        placeholder.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
        onHeightChange()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let inner = bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
        textView.frame = CGRect(x: Self.horizontalInset, y: Self.verticalInset, width: inner.width, height: inner.height)
        placeholder.frame = CGRect(x: inner.minX, y: inner.minY - 1, width: inner.width, height: Self.lineHeight + 2)
    }
}

/// Return sends; Option- or Shift-Return adds a newline; IME marked text
/// keeps Return for its own commit.
final class HomeFieldTextView: NSTextView {
    var onSend: () -> Void = {}
    var onChange: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.option) || flags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onSend()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onChange()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onChange()
    }
}
