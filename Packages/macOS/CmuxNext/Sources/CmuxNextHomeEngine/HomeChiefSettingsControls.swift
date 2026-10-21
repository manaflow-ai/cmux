import AppKit
import CmuxNextDesign

/// The Chief's avatar in the settings card: its picture (or text) in a disc;
/// a click opens the menu that changes it.
@MainActor
final class HomeChiefAvatarButton: NSButton {
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        font = Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The picture fills the disc; text (an emoji, initials) sits centered on the theme's fill.
    func show(picture: NSImage?, text: String?) {
        image = picture
        imagePosition = picture == nil ? .noImage : .imageOnly
        title = picture == nil ? (text ?? "") : ""
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme {
            layer?.backgroundColor = image == nil ? Palette.hoverFill.cgColor : nil
            contentTintColor = Palette.textPrimary
        }
    }
}

/// A borderless text button drawn as a plain link: the theme's accent (or
/// `ink`), underlined while hovered. Show Traces, Show Memory, Diagnostics.
@MainActor
final class HomeChiefLinkButton: NSButton {
    /// Nil draws the theme's accent.
    var ink: ThemeInk? { didSet { applyTitle() } }
    var textFont: NSFont = Typography.caption { didSet { applyTitle() } }
    private var text = ""
    private var isHovering = false { didSet { applyTitle() } }
    private var tracking: NSTrackingArea?

    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        text = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
        applyTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitle()
    }

    private func applyTitle() {
        let color = performWithTheme { () -> NSColor in
            switch ink {
            case .primary?: Palette.textPrimary
            case .secondary?: Palette.textSecondary
            case .tertiary?: Palette.textTertiary
            case .danger?: Palette.danger
            case nil: Palette.accent
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: color]
        if isHovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
        invalidateIntrinsicContentSize()
    }
}
