public import AppKit

/// A dialog button in its ``CmuxDialogButtonLook``: the default button a solid accent fill, a
/// destructive one in the danger color, the others a theme gray (never the system accent), every
/// title 4.5:1 on its fill. It draws a focus ring in `Palette.focusRing` around itself while it has
/// keyboard focus (outside the fill, so it shows on a solid one too).
@MainActor
public final class CmuxDialogButtonView: NSButton {
    public private(set) var button: CmuxDialogButton
    /// The key that presses this button, drawn after its title (u2647); nil draws none.
    public let keyHint: CmuxDialogKeyHint?
    private var isHovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?
    private var hasFocus = false { didSet { refresh() } }
    /// The keyboard focus ring, just outside the button.
    private let focusRing = CALayer()

    /// A button drawing `hint` after its title. The hint only labels the key: the host
    /// answers it (``CmuxDialogView`` through ``CmuxDialogKeys``), so pass the hint that
    /// ``CmuxDialogKeys/hint(for:in:)`` gives for the host's spec.
    public init(_ button: CmuxDialogButton, hint: CmuxDialogKeyHint?, target: AnyObject?, action: Selector) {
        self.button = button
        keyHint = hint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier("cmux.dialog.button.\(button.id)")
        setAccessibilityLabel(button.title)
        // VoiceOver reads the key after the title; the label stays the title (automation finds it).
        setAccessibilityHelp(hint?.spokenName)
        heightAnchor.constraint(equalToConstant: CmuxDialogMetrics.buttonHeight).isActive = true
        focusRing.borderWidth = 2
        focusRing.isHidden = true
        layer?.addSublayer(focusRing)
        refresh()
    }

    /// A button outside a ``CmuxDialogView`` (a sheet or panel of its own) that answers its
    /// own key and shows it: Return for a `.default` button, Escape for a `.cancel` one, else
    /// Command plus the button's `key`; a `.normal` button with no `key` shows none.
    public convenience init(standalone button: CmuxDialogButton, target: AnyObject?, action: Selector) {
        let hint: CmuxDialogKeyHint? = switch button.role {
        case .default: .return
        case .cancel: .escape
        case .destructive, .normal: button.key.map(CmuxDialogKeyHint.command)
        }
        self.init(button, hint: hint, target: target, action: action)
        keyEquivalent = hint?.keyEquivalent ?? ""
        keyEquivalentModifierMask = hint?.modifierMask ?? []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isEnabled: Bool { didSet { refresh() } }

    /// Shows a new title in place (Copy Link turning into "Copied").
    public func retitle(_ title: String) {
        guard title != button.title else { return }
        button.title = title
        setAccessibilityLabel(title)
        refresh()
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }
    public override var isHighlighted: Bool { didSet { refresh() } }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { hasFocus = true }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { hasFocus = false }
        return resigned
    }

    /// Space presses the focused button (Return always presses the default).
    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { performClick(nil) } else { super.keyDown(with: event) }
    }

    public override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: max(ceil(size.width) + Metrics.space4 * 2, CmuxDialogMetrics.buttonMinWidth),
                      height: CmuxDialogMetrics.buttonHeight)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true }
    public override func mouseExited(with event: NSEvent) { isHovering = false }

    public override func layout() {
        super.layout()
        let outset = Self.focusRingOutset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusRing.frame = bounds.insetBy(dx: -outset, dy: -outset)
        focusRing.cornerRadius = CmuxDialogMetrics.buttonCornerRadius + outset
        CATransaction.commit()
    }

    /// How far outside the fill the focus ring sits.
    static let focusRingOutset: CGFloat = 3

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    /// The look this button draws now (its role, hover and press, in its theme scope).
    var look: CmuxDialogButtonLook {
        let state: CmuxDialogButtonLook.State = isHighlighted ? .pressed : isHovering ? .hover : .rest
        return performWithTheme {
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            return CmuxDialogButtonLook(role: button.role, tokens: tokens, state: state,
                                        filledDestructive: ChromeTunables.filledDestructiveDialogButton.value,
                                        card: CmuxDialogButtonLook.cardSurfaces(tokens, lift: ChromeTunables.opaqueOverlayLift.value))
        }
    }

    private func refresh() {
        let look = look
        performWithTheme {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = look.fill.nsColor.cgColor
            layer?.cornerRadius = CmuxDialogMetrics.buttonCornerRadius
            focusRing.isHidden = !hasFocus
            focusRing.borderColor = Palette.focusRing.cgColor
            CATransaction.commit()
            alphaValue = isEnabled ? 1 : 0.45
            let font = button.role == .default ? Typography.bodyEmphasized : Typography.body
            attributedTitle = keyHint?.attributedTitle(button.title, font: font, color: look.title.nsColor, hintColor: look.keyHint.nsColor)
                ?? NSAttributedString(string: button.title, attributes: [.foregroundColor: look.title.nsColor, .font: font])
        }
        invalidateIntrinsicContentSize()
    }
}

/// Sizes shared by every dialog.
@MainActor
enum CmuxDialogMetrics {
    static var width: CGFloat { 380 * Typography.userScale }
    static var buttonHeight: CGFloat { 26 * Typography.userScale }
    static var buttonMinWidth: CGFloat { 72 * Typography.userScale }
    static var buttonCornerRadius: CGFloat { 7 }
    static var fieldHeight: CGFloat { 24 * Typography.userScale }
    static var padding: CGFloat { Metrics.space5 }
    static var spacing: CGFloat { Metrics.space3 }
    static var iconSize: CGFloat { 40 }
}
