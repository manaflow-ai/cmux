import AppKit
import CmuxNextDesign

/// The message field: a floating Liquid Glass capsule over the transcript's
/// bottom edge (floating chrome, never behind transcript text it covers:
/// the transcript reserves the space). Return sends, Shift-Return or
/// Option-Return adds a line; the field grows to five lines.
final class ComposerView: NSView, NSTextViewDelegate {
    /// The text to send and the text's frame in this view (y-up points).
    var onSend: ((String, CGRect) -> Void)?
    /// The preferred height changed (lines added or removed).
    var onHeightChange: (() -> Void)?
    let textView = ComposerTextView()
    private let glass: NSGlassEffectView
    private let placeholder = NSTextField(labelWithString: "")
    static let maxLines = 5

    override init(frame: NSRect) {
        glass = NSGlassEffectView()
        super.init(frame: frame)
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.writingToolsBehavior = .none
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onReturn = { [weak self] in self?.send() }
        placeholder.stringValue = HomeStrings.messagePlaceholder
        placeholder.isEditable = false
        placeholder.isSelectable = false
        placeholder.drawsBackground = false
        placeholder.isBordered = false
        let content = NSView()
        content.addSubview(placeholder)
        content.addSubview(textView)
        glass.contentView = content
        addSubview(glass)
        setAccessibilityLabel(HomeStrings.messagePlaceholder)
    }

    required init?(coder: NSCoder) { nil }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
    }

    private var lineHeight: CGFloat { ceil(Typography.body.ascender - Typography.body.descender + Typography.body.leading) }

    private var lineCount: Int {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return 1 }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        return max(1, min(Self.maxLines, Int((used / max(1, lineHeight)).rounded())))
    }

    /// The capsule's height for the current text.
    var preferredHeight: CGFloat { CGFloat(lineCount) * lineHeight + 2 * Metrics.space4 }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let insetX = Metrics.space5, insetY = Metrics.space4
        let textFrame = CGRect(x: insetX, y: insetY, width: max(1, bounds.width - 2 * insetX),
                               height: max(lineHeight, bounds.height - 2 * insetY))
        textView.frame = textFrame
        textView.textContainer?.containerSize = CGSize(width: textFrame.width, height: .greatestFiniteMagnitude)
        placeholder.frame = CGRect(x: insetX, y: insetY, width: textFrame.width, height: lineHeight)
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme {
            glass.cornerRadius = min(bounds.height / 2, lineHeight / 2 + Metrics.space4)
            glass.tintColor = Palette.glassTint
            textView.font = Typography.body
            textView.textColor = Palette.textPrimary
            textView.insertionPointColor = Palette.textPrimary
            textView.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
            placeholder.font = Typography.body
            placeholder.textColor = Palette.textTertiary
        }
    }

    /// The text's frame in this view, for the send flight.
    var textFrameInSelf: CGRect {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return textView.frame }
        let used = manager.usedRect(for: container)
        let frame = textView.frame
        return CGRect(x: frame.minX, y: frame.maxY - max(lineHeight, used.height), width: frame.width,
                      height: max(lineHeight, used.height))
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        onHeightChange?()
    }

    private func send() {
        let value = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSend?(value, textFrameInSelf)
        text = ""
    }
}

/// The composer's text view: Return sends instead of inserting a line.
final class ComposerTextView: NSTextView {
    var onReturn: (() -> Void)?

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if !flags.contains(.shift) && !flags.contains(.option) {
                onReturn?()
                return
            }
            super.doCommand(by: #selector(insertNewlineIgnoringFieldEditor(_:)))
            return
        }
        super.doCommand(by: selector)
    }
}
