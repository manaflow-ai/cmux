import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The incognito window's mark in the sidebar's titlebar row: a glyph and
/// "Incognito" in secondary text on a subtle gray rounded rectangle (no accent
/// color). In the top row a press on it never moves the window.
final class IncognitoBadgeView: NSView, TitlebarPressDeciding {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: WindowStrings.incognitoBadge)

    /// The glyph drawn (tests).
    var glyph: NSImage? { icon.image }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = Typography.caption
        icon.image = NSImage.icon(.browserIncognito, size: .iconRowSize(forLabelPointSize: label.font?.pointSize ?? 11))
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

    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .staysPut }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.chipCornerRadius(height: bounds.height)
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
