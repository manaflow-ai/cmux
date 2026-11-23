import AppKit
import CmuxNextDesign

/// The native store's one-click button (Install, Open, Hide, Show, Remove, Update): a text button that rounds
/// as a tab (``Metrics/buttonCornerRadius``). Primary is filled with the text ink, as the React store's
/// black or white pill; secondary rests on the hover fill; plain has no fill until the pointer is over it. A
/// held button changes only its fill (design/pressed-state.md).
final class AppStoreButton: ClickableButton {
    enum Style {
        case primary, secondary, plain
    }

    static var height: CGFloat { ceil(TypeScale.bodyLineHeight) + 2 * Metrics.space1 }

    private let style: Style
    private var plainTitle: String
    private let handler: @MainActor () -> Void
    private var pointerHover: PointerHover?
    private var isHovered = false
    private var isHeld = false

    init(_ title: String, style: Style, identifier: String? = nil, action: @escaping @MainActor () -> Void) {
        self.style = style
        plainTitle = title
        handler = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.actions = ["backgroundColor": NSNull()]
        target = self
        self.action = #selector(clicked)
        setAccessibilityLabel(title)
        if let identifier { setAccessibilityIdentifier(identifier) }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        pointerHover = PointerHover(self) { [weak self] hovering in
            self?.isHovered = hovering
            self?.applyStyle()
        }
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        let drawn = cell.map { ceil($0.cellSize.width) } ?? 0
        return NSSize(width: max(ceil(text.width) + 2 * Metrics.space3, drawn), height: Self.height)
    }

    nonisolated override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.buttonCornerRadius(fitting: bounds.size)
    }

    override func mouseDown(with event: NSEvent) {
        isHeld = true
        applyStyle()
        super.mouseDown(with: event)
        isHeld = false
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    @objc private func clicked() { handler() }

    private func applyStyle() {
        guard let layer else { return }
        performWithTheme {
            let ink: NSColor
            let fill: NSColor?
            switch style {
            case .primary:
                ink = Palette.textOnPrimary
                let base = Palette.textPrimary
                // The held fill is the hover's fill a step deeper; the title stays as it is.
                fill = isHeld ? base.blended(withFraction: 0.25, of: Palette.textOnPrimary)
                    : isHovered ? base.blended(withFraction: 0.12, of: Palette.textOnPrimary) : base
            case .secondary:
                ink = Palette.textPrimary
                fill = ChromeHover.fillColor(ChromeHover.State(hovering: isHovered && isEnabled, pressed: isHeld), rest: Palette.hoverFill)
            case .plain:
                ink = Palette.textPrimary
                fill = ChromeHover.fillColor(ChromeHover.State(hovering: isHovered && isEnabled, pressed: isHeld))
            }
            ChromeHover.paint(layer, fill, animated: window != nil, pressed: isHeld)
            attributedTitle = NSAttributedString(string: plainTitle, attributes: [
                .font: Typography.bodyEmphasized,
                .foregroundColor: isEnabled ? ink : ink.withAlphaComponent(0.5),
            ])
        }
        invalidateIntrinsicContentSize()
    }
}
