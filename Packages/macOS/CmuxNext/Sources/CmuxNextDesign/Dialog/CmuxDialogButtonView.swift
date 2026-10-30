public import AppKit

/// A dialog button: gray fills from the theme (no system accent), the
/// default button prominent, a destructive one in the danger color. It
/// draws a focus ring in `Palette.focusRing` while it has keyboard focus.
@MainActor
public final class CmuxDialogButtonView: ClickableButton {
    public private(set) var button: CmuxDialogButton
    /// The key that presses this button, drawn after its title (u2647); nil draws none.
    public let keyHint: CmuxDialogKeyHint?
    private var isHovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?
    private var hasFocus = false { didSet { refresh() } }

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

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        let prominent = button.role == .default
        performWithTheme {
            var fill = prominent ? Palette.selectionFill : Palette.hoverFill
            if isHighlighted || isHovering { fill = prominent ? Palette.pressedFill : Palette.selectionFill }
            layer?.backgroundColor = fill.cgColor
            alphaValue = isEnabled ? 1 : 0.45
            layer?.cornerRadius = CmuxDialogMetrics.buttonCornerRadius
            layer?.borderWidth = hasFocus ? 2 : 0
            layer?.borderColor = Palette.focusRing.cgColor
            let color = button.role == .destructive ? Palette.danger : Palette.textPrimary
            let font = prominent ? Typography.bodyEmphasized : Typography.body
            attributedTitle = keyHint?.attributedTitle(button.title, font: font, color: color)
                ?? NSAttributedString(string: button.title, attributes: [.foregroundColor: color, .font: font])
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
