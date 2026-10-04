import AppKit

/// The compose field: a Liquid Glass capsule holding a real NSTextView
/// (TextKit 2: IME, undo, spell checking, services). Return sends,
/// Option- or Shift-Return inserts a newline; marked text owns Return.
final class HomeFieldView: NSView {
    let glass = NSGlassEffectView()
    let textView = HomeFieldTextView(usingTextLayoutManager: true)
    private let placeholder = NSTextField(labelWithString: "")
    /// The glass's content: the glass sizes its content view to the field,
    /// so the text view sits inside this holder at the field's insets.
    private let textHolder = NSView()
    /// Reports the new height after every edit (the host relayouts).
    var onHeightChange: () -> Void = {}
    var onSend: () -> Void = {}

    static let maxLines = 8
    /// The 13 pt reference metrics; `scale` multiplies them.
    static let baseFontSize: CGFloat = 13
    static let baseLineHeight: CGFloat = 16
    static let baseHorizontalInset: CGFloat = 12
    static let baseVerticalInset: CGFloat = 7

    /// The user's text size relative to 13 pt (the transcript's `textScale`).
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            applyFont()
            needsLayout = true
            onHeightChange()
        }
    }

    var lineHeight: CGFloat { (Self.baseLineHeight * scale).rounded() }
    var horizontalInset: CGFloat { (Self.baseHorizontalInset * scale).rounded() }
    var verticalInset: CGFloat { (Self.baseVerticalInset * scale).rounded() }

    func height(lines: Int) -> CGFloat { 2 * verticalInset + lineHeight * CGFloat(lines) + (lines >= 2 ? 1 : 0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glass)
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
        placeholder.textColor = .placeholderTextColor
        textHolder.addSubview(textView)
        glass.contentView = textHolder
        addSubview(placeholder)
        applyFont()
    }

    private func applyFont() {
        glass.cornerRadius = height(lines: 1) / 2
        let font = NSFont.systemFont(ofSize: Self.baseFontSize * scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        textView.font = font
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        // Restyle committed text only: IME marked text keeps its own
        // attributes (the scale applies to it once it is committed).
        if let storage = textView.textStorage, storage.length > 0, !textView.hasMarkedText() {
            storage.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: storage.length))
        }
        placeholder.font = font
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Lines the draft needs at the current width (1...maxLines).
    var lines: Int {
        guard let manager = textView.textLayoutManager else { return 1 }
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer.height
        let n = Int((max(used, lineHeight) / lineHeight).rounded())
        return min(Self.maxLines, max(1, n))
    }

    var preferredHeight: CGFloat { height(lines: lines) }

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
        let inner = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        textView.frame = CGRect(x: horizontalInset, y: verticalInset, width: inner.width, height: inner.height)
        placeholder.frame = CGRect(x: inner.minX, y: inner.minY - 1, width: inner.width, height: lineHeight + 2)
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
