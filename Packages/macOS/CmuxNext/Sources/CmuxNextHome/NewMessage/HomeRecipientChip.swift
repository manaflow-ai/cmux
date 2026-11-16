import AppKit
import CmuxNextDesign

/// One token in the To: field: the name on a soft accent pill, or in red
/// with a red tint when it names nobody (Messages' unknown recipient). A
/// click selects it (a deeper tint) and Backspace then removes it, as in
/// Messages; VoiceOver reads it as a "Remove <name>" button.
final class HomeRecipientChip: NSView {
    static let height: CGFloat = 22
    var onRemove: () -> Void = {}
    var onSelect: () -> Void = {}
    var isSelected = false { didSet { if isSelected != oldValue { applyColors() } } }
    let token: HomeRecipientToken
    let label = ThemedLabel(labelWithString: "")

    init(token: HomeRecipientToken) {
        self.token = token
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        label.stringValue = token.text
        label.font = Typography.body
        label.lineBreakMode = .byTruncatingTail
        label.themeColor = { [isValid = token.isValid] in isValid ? Palette.litGlyph : Palette.danger }
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(HomeConversationStrings.removeRecipient(token.text))
        setAccessibilityIdentifier("cmux.home.newMessage.token")
        if !token.isValid { themedToolTip = HomeConversationStrings.unknownRecipient(token.text) }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The pill's width for its text.
    var preferredWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 20 }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        // The text box sits 10 pt in from each side; the frame adds the label's padding around it
        // (a frame the size of the text alone truncated every name).
        label.frame = label.frame(forAlignmentRect: NSRect(x: 10, y: (bounds.height - size.height) / 2,
                                                           width: max(0, bounds.width - 20), height: size.height))
    }

    override func mouseDown(with event: NSEvent) { onSelect() }

    override func accessibilityPerformPress() -> Bool {
        onRemove()
        return true
    }

    func applyColors() {
        let valid = token.isValid, alpha: CGFloat = isSelected ? 0.36 : 0.16
        layer?.backgroundColor = performWithTheme { (valid ? Palette.accent : Palette.danger).withAlphaComponent(alpha).cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}
