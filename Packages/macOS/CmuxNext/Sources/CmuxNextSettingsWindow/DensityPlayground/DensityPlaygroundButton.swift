import AppKit
import CmuxNextDesign

/// A Density Playground button: the Settings window's small gray button (its title on the theme's hover fill, the
/// selection fill while pressed), or a bare icon (a row's reset, its glyph in the secondary ink) that takes the hover
/// fill only under the pointer. Colors are the ``SettingsTheme`` tokens, read again by ``applyStyle()``; sizes are
/// fixed, apart from the density being tuned.
final class DensityPlaygroundButton: ClickableButton {
    /// The ink of a text button's title.
    enum Ink { case primary, danger }

    private let iconOnly: Bool
    private var plainTitle: String
    /// The title's ink (Delete armed is in the danger ink).
    var ink: Ink = .primary {
        didSet { if ink != oldValue { applyStyle() } }
    }
    /// An image after the title (the density pop-up's chevron).
    var trailingImage: NSImage? {
        didSet {
            image = trailingImage
            imagePosition = trailingImage == nil ? .noImage : .imageTrailing
            invalidateIntrinsicContentSize()
        }
    }
    /// The pointer and press state only: the fills are painted by ``applyStyle()`` on the button's own layer.
    private lazy var hover = ChromeHover(self, cornerRadius: Metrics.buttonCornerRadius)

    static let height: CGFloat = 22
    static let titlePadding: CGFloat = 8
    static let trailingGap: CGFloat = 4

    /// A text button titled `title`.
    init(title: String, target: AnyObject?, action: Selector?) {
        iconOnly = false
        plainTitle = title
        super.init(frame: .zero)
        configure(target: target, action: action)
        setAccessibilityLabel(title)
    }

    /// An icon button: `image` (a template) in the secondary ink, named `label` for VoiceOver.
    init(image: NSImage, label: String, target: AnyObject?, action: Selector?) {
        iconOnly = true
        plainTitle = ""
        super.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        configure(target: target, action: action)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(target: AnyObject?, action: Selector?) {
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        self.target = target
        self.action = action
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        if iconOnly { widthAnchor.constraint(equalToConstant: Self.height).isActive = true }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        hover.paintsFill = false
        hover.followPointer(isHoverable: { [weak self] in self?.isEnabled == true }, onChange: { [weak self] in self?.applyStyle() })
        applyStyle()
    }

    /// The title without the trailing image.
    override var title: String {
        get { plainTitle }
        set {
            guard newValue != plainTitle else { return }
            plainTitle = newValue
            setAccessibilityLabel(newValue)
            applyStyle()
            invalidateIntrinsicContentSize()
        }
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { applyStyle() } }
    }

    override var intrinsicContentSize: NSSize {
        guard !iconOnly else { return NSSize(width: Self.height, height: Self.height) }
        let text = attributedTitle.size()
        let trailing = trailingImage.map { ceil($0.size.width) + Self.trailingGap } ?? 0
        // Never narrower than the cell needs to draw the whole title and image.
        let drawn = cell.map { ceil($0.cellSize.width) } ?? 0
        return NSSize(width: max(ceil(text.width) + trailing, drawn) + Self.titlePadding * 2, height: Self.height)
    }

    nonisolated override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    /// Reads the tokens again (a state, title or theme change).
    func applyStyle() {
        let tokens = SettingsTheme.shared.tokens
        let lit = hover.state.pressed || hover.state.hovering
        if iconOnly {
            contentTintColor = (lit ? tokens.textPrimary : tokens.textSecondary).nsColor
            setLayerFill(hover.state.pressed ? tokens.selectionFill.nsColor : hover.state.hovering ? tokens.hoverFill.nsColor : nil)
            return
        }
        let color = !isEnabled ? tokens.textTertiary : ink == .danger ? tokens.danger : tokens.textPrimary
        attributedTitle = NSAttributedString(string: plainTitle, attributes: [
            .font: DensityPlaygroundView.Size.body, .foregroundColor: color.nsColor,
        ])
        contentTintColor = tokens.textSecondary.nsColor
        setLayerFill(hover.state.pressed && isEnabled ? tokens.selectionFill.nsColor : tokens.hoverFill.nsColor)
    }

    private func setLayerFill(_ color: NSColor?) {
        wantsLayer = true
        layer?.cornerRadius = Metrics.buttonCornerRadius(fitting: bounds.size)
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = color?.cgColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.buttonCornerRadius(fitting: bounds.size)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        hover.state.pressed = true
        applyStyle()
        super.mouseDown(with: event)
        hover.state.pressed = false
        applyStyle()
    }
}
