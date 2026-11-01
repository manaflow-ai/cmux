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
    /// A toggle that is on (a toast's Details while they show): lit with the hover fill until off,
    /// wherever the pointer goes and in calm mode too (`ChromeHover.State.lit`). Never the
    /// selection fill (the accent).
    public var isOn = false {
        didSet { if isOn != oldValue { changeHover { $0.lit = isOn } } }
    }
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
        return NSSize(width: ceil(text.width) + Self.titlePadding * 2, height: Self.closeSide + 2)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applyStyle() {
        performWithTheme {
            switch style {
            case .action:
                attributedTitle = NSAttributedString(string: plainTitle, attributes: [
                    .font: Typography.bodyEmphasized,
                    .foregroundColor: Palette.textPrimary,
                ])
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
