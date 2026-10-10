public import AppKit

/// A dialog button: gray fills from the theme (no system accent), the
/// default button prominent, a destructive one in the danger color. It
/// draws a focus ring in `Palette.focusRing` while it has keyboard focus.
@MainActor
public final class CmuxDialogButtonView: NSButton {
    public private(set) var button: CmuxDialogButton
    /// What a press grants (`AXCmuxConfirmKind`): the dialog's kind, `none` for its cancel button.
    public let confirmKind: CmuxDialogConfirmKind
    private var isHovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?
    private var hasFocus = false { didSet { refresh() } }

    public init(_ button: CmuxDialogButton, confirmKind: CmuxDialogConfirmKind = .none, target: AnyObject?, action: Selector) {
        self.button = button
        self.confirmKind = confirmKind
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
        heightAnchor.constraint(equalToConstant: CmuxDialogMetrics.buttonHeight).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows a new title in place (Copy Link turning into "Copied").
    public func retitle(_ title: String) {
        guard title != button.title else { return }
        button.title = title
        setAccessibilityLabel(title)
        refresh()
    }

    @available(macOS, deprecated: 10.10, message: "custom accessibility attribute")
    nonisolated public override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [CmuxDialogConfirmKind.accessibilityAttribute]
    }

    @available(macOS, deprecated: 10.10, message: "custom accessibility attribute")
    nonisolated public override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        attribute == CmuxDialogConfirmKind.accessibilityAttribute ? confirmKind.rawValue : super.accessibilityAttributeValue(attribute)
    }

    /// An accessibility press is not the person's pointer (cx-zk9t): a user-only button
    /// refuses it unless VoiceOver or Switch Control runs (`CmuxPersonInput`); Cancel and
    /// every `none` button accept it.
    public override func accessibilityPerformPress() -> Bool {
        if confirmKind.isUserOnly, !CmuxPersonInput.shared.acceptsAccessibilityPress() { return false }
        return super.accessibilityPerformPress()
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
            layer?.cornerRadius = CmuxDialogMetrics.buttonCornerRadius
            layer?.borderWidth = hasFocus ? 2 : 0
            layer?.borderColor = Palette.focusRing.cgColor
            attributedTitle = NSAttributedString(string: button.title, attributes: [
                .foregroundColor: button.role == .destructive ? Palette.danger : Palette.textPrimary,
                .font: prominent ? Typography.bodyEmphasized : Typography.body,
            ])
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
