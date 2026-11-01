public import AppKit

/// A toast's action (Undo, Reopen, Details) or close button: a clear text button in
/// the primary text color, or a small xmark, on the toast's own surface,
/// with the shared hover fill only under the pointer. No second capsule, no
/// accent color.
@MainActor
public final class CmuxToastButton: ClickableButton {
    public enum Style { case action, close }

    /// Horizontal padding of the action title inside its hover fill.
    static let titlePadding: CGFloat = 6
    static let closeSide: CGFloat = 20
    let style: Style
    private var plainTitle: String
    /// A disclosure that is open (a toast's Details while they show): a quiet text link, the
    /// title in the secondary text color with an up chevron after it, never a filled chip. Only
    /// the pointer lights it, like any toast button (Leo, 2026-11-01: "the details toast doesnt
    /// look very good").
    public var isOn = false {
        didSet {
            guard isOn != oldValue, style == .action else { return }
            image = isOn ? Self.disclosureChevron : nil
            imagePosition = isOn ? .imageTrailing : .noImage
            applyStyle()
            invalidateIntrinsicContentSize()
        }
    }
    /// The open disclosure's chevron: the close button's size and weight, so the two read as a pair.
    static let disclosureChevron = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
    /// Room between an open disclosure's title and its chevron.
    static let chevronGap: CGFloat = 4
    /// The fill the button shows now (tests): nil when it shows none.
    var shownFill: NSColor? { ChromeHover.fillColor(hover.state) }
    private lazy var hover = ChromeHover(self, cornerRadius: Metrics.itemCornerRadius, behindContent: true)

    init(style: Style, title: String, target: AnyObject?, action: Selector?) {
        self.style = style
        plainTitle = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
        switch style {
        case .action:
            heightAnchor.constraint(equalToConstant: Self.closeSide + 2).isActive = true
        case .close:
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            image = NSImage(systemSymbolName: "xmark", accessibilityDescription: title)?.withSymbolConfiguration(config)
            imagePosition = .imageOnly
            widthAnchor.constraint(equalToConstant: Self.closeSide).isActive = true
            heightAnchor.constraint(equalToConstant: Self.closeSide).isActive = true
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        hover.refresh(animated: false)
        // Hover follows the pointer and the toast's slot (cx-3wu5).
        hover.followPointer(onChange: { [weak self] in self?.applyStyle() })
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize {
        guard style == .action else { return NSSize(width: Self.closeSide, height: Self.closeSide) }
        let text = attributedTitle.size()
        let chevron = image.map { ceil($0.size.width) + Self.chevronGap } ?? 0
        return NSSize(width: ceil(text.width) + chevron + Self.titlePadding * 2, height: Self.closeSide + 2)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applyStyle() {
        performWithTheme {
            switch style {
            case .action:
                // Open, it is a quiet link (secondary text, lit to primary under the pointer).
                let color = !isOn || hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary
                attributedTitle = NSAttributedString(string: plainTitle, attributes: [
                    .font: Typography.bodyEmphasized,
                    .foregroundColor: color,
                ])
                contentTintColor = color
            case .close:
                contentTintColor = hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary
            }
        }
    }

    /// Shows `title` (Details while off, Hide Details while on): VoiceOver reads it and the button
    /// sizes to it.
    func setTitle(_ title: String) {
        guard style == .action, title != plainTitle else { return }
        plainTitle = title
        setAccessibilityLabel(title)
        applyStyle()
        invalidateIntrinsicContentSize()
    }

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        var state = hover.state
        change(&state)
        hover.state = state
        applyStyle()
    }

    public override func layout() {
        super.layout()
        hover.layout()
    }

    public override func mouseDown(with event: NSEvent) {
        changeHover { $0.pressed = true }
        super.mouseDown(with: event)
        changeHover { $0.pressed = false }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
        applyStyle()
    }
}
