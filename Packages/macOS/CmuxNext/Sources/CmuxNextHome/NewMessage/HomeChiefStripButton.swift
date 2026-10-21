import AppKit
import CmuxNextDesign

/// One Chief on New Message's Chiefs strip: "+ Name" on a neutral gray capsule (the To: field's
/// tokens are accent pills; these are offers, not choices). A click adds the Chief.
final class HomeChiefStripButton: NSView {
    static let height: CGFloat = 24
    var onPress: () -> Void = {}
    let label = ThemedLabel(labelWithString: "")
    private var pressed = false { didSet { applyColors() } }

    init(name: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        label.stringValue = "+ " + name
        label.font = Typography.body
        label.ink = .primary
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(HomeConversationStrings.composeAddChief(name))
        setAccessibilityIdentifier("cmux.home.newMessage.chief")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var preferredWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 22 }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 11, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 22), height: size.height)
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }

    func applyColors() {
        let alpha: CGFloat = pressed ? 0.2 : 0.08
        layer?.backgroundColor = performWithTheme { NSColor.labelColor.withAlphaComponent(alpha).cgColor }
        layer?.borderWidth = 0.5
        layer?.borderColor = performWithTheme { Palette.separator.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}
