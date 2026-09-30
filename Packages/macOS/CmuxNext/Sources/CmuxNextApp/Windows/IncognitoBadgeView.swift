import AppKit
import CmuxNextDesign

/// The incognito window's mark in the sidebar's titlebar row: a glyph and
/// "Incognito" in secondary text on a subtle gray capsule (no accent
/// color). Clicks pass through to the titlebar row, which moves the window.
final class IncognitoBadgeView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: WindowStrings.incognitoBadge)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .medium)
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = Metrics.space1
        stack.edgeInsets = NSEdgeInsets(top: 2, left: Metrics.space2, bottom: 2, right: Metrics.space2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = WindowStrings.incognitoHelp
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(WindowStrings.incognitoHelp)
        setAccessibilityIdentifier("window.incognito.badge")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Theme tokens only: secondary text on the hover gray.
    func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textSecondary
            label.textColor = Palette.textSecondary
            layer?.backgroundColor = Palette.hoverFill.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
