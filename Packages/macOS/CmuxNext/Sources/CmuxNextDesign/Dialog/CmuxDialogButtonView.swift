public import AppKit

/// A dialog button in its ``CmuxDialogButtonLook``: the default button a solid accent fill, a
/// destructive one in the danger color, the others a theme gray (never the system accent), every
/// title 4.5:1 on its fill. It draws a focus ring (`Palette.focusRing`, fit to 3:1 on the card) around itself while it has
/// keyboard focus (outside the fill, so it shows on a solid one too).
@MainActor
public final class CmuxDialogButtonView: ClickableButton {
    public private(set) var button: CmuxDialogButton
    /// The key that presses this button, drawn after its title (u2647); nil draws none.
    public let keyHint: CmuxDialogKeyHint?
    /// Drawn as text with no fill at rest (``CmuxDialogButtonLook`` `quiet`): a destructive choice in a
    /// ``CmuxDialogSpec/Layout/safeDefault`` dialog.
    public let isQuiet: Bool
    private var isHovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?
    private var hasFocus = false { didSet { refresh() } }
    /// The keyboard focus ring, just outside the button.
    private let focusRing = CALayer()
    /// On a solid fill, a line of the card's color just inside the button's edge, between the fill and
    /// the ring, so the ring reads apart from a fill of its own color (the accent default button).
    private let focusGap = CALayer()
    /// The key drawn on a plate at the trailing end (a cmux dialog's card), instead of as text after the title.
    private let keycapView: CmuxDialogKeycapView?
    /// The button's corner: rounder with a keycap, so the plate inside keeps one inset all round.
    private var cornerRadius: CGFloat {
        keycapView == nil ? CmuxDialogMetrics.buttonCornerRadius : CmuxDialogMetrics.keycapButtonCornerRadius
    }

    /// A button drawing `hint` after its title. The hint only labels the key: the host
    /// answers it (the overlay page's dialog through ``CmuxDialogKeys``), so pass the hint that
    /// ``CmuxDialogKeys/hint(for:in:)`` gives for the host's spec. `keycap` draws the hint on a plate at the
    /// button's trailing end (the cmux dialog card, ``CmuxDialogView``), on a taller, rounder button.
    public init(_ button: CmuxDialogButton, hint: CmuxDialogKeyHint?, quiet: Bool = false, keycap: Bool = false,
                target: AnyObject?, action: Selector) {
        self.button = button
        keyHint = hint
        isQuiet = quiet
        keycapView = keycap ? hint.map { CmuxDialogKeycapView($0.glyph) } : nil
        super.init(frame: .zero)
        if let keycapView {
            keycapView.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.keycap.\(button.id)")
            addSubview(keycapView)
        }
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
        heightAnchor.constraint(equalToConstant: keycapView == nil ? CmuxDialogMetrics.buttonHeight : CmuxDialogMetrics.keycapButtonHeight).isActive = true
        focusRing.borderWidth = Self.focusRingWidth
        focusRing.isHidden = true
        focusGap.borderWidth = Self.focusGapWidth
        focusGap.isHidden = true
        // The ring sits outside the fill: nothing may clip it.
        clipsToBounds = false
        refresh()
    }

    /// A button outside a cmux dialog (a sheet or panel of its own) that answers its
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
        if keycapView != nil {
            // The title carries the keycap's room as trailing kern (``keycapRoom``): centered, it sits at the leading inset.
            return NSSize(width: max(ceil(size.width) + CmuxDialogMetrics.keycapLeading * 2, CmuxDialogMetrics.buttonMinWidth),
                          height: CmuxDialogMetrics.keycapButtonHeight)
        }
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
        // AppKit may replace a button's backing layer after init: the ring follows the current one.
        if let layer, focusRing.superlayer !== layer {
            layer.masksToBounds = false
            layer.addSublayer(focusGap)
            layer.addSublayer(focusRing)
        }
        let outset = Self.focusRingOutset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusRing.frame = bounds.insetBy(dx: -outset, dy: -outset)
        focusRing.cornerRadius = cornerRadius + outset
        // Just outside the fill, so a focused button keeps its full size and its edges line up with
        // its neighbors' (drawn inside, the band shrank the fill 3 px on every side).
        let gap = Self.focusGapWidth
        focusGap.frame = bounds.insetBy(dx: -gap, dy: -gap)
        focusGap.cornerRadius = cornerRadius + gap
        CATransaction.commit()
        if let keycapView {
            let inset = CmuxDialogMetrics.keycapInset
            let height = max(0, bounds.height - inset * 2)
            let width = keycapView.width(forHeight: height)
            keycapView.frame = NSRect(x: bounds.maxX - inset - width, y: inset, width: width, height: height)
        }
    }

    /// The overlay surface (the dialog's card) this button draws on, if any.
    private var enclosingSurface: OverlaySurfaceView? {
        var view = superview
        while let current = view {
            if let surface = current as? OverlaySurfaceView { return surface }
            view = current.superview
        }
        return nil
    }

    /// How far outside the button the focus ring reaches: the gap (``focusGap``, on a solid fill)
    /// then the ring's line. Dialog button rows are `Metrics.space2` (4 pt) apart, and a ring
    /// reaching 4 pt ran into the next button; 2.5 pt leaves 1.5 pt to it. On a translucent fill
    /// there is no gap band and the ring still sits 1 pt off the fill, the same place.
    static let focusRingOutset: CGFloat = focusGapWidth + focusRingWidth
    static let focusRingWidth: CGFloat = 1.5
    static let focusGapWidth: CGFloat = 1

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
            return CmuxDialogButtonLook(role: button.role, tokens: tokens, state: state, quiet: isQuiet,
                                        card: CmuxDialogButtonLook.cardSurfaces(tokens, lift: ChromeTunables.opaqueOverlayLift.value))
        }
    }

    private func refresh() {
        let look = look
        performWithTheme {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = look.fill.nsColor.cgColor
            layer?.cornerRadius = cornerRadius
            focusRing.isHidden = !hasFocus
            focusRing.borderColor = look.focusRing.nsColor.cgColor
            // Only a solid fill needs the gap: a translucent one already reads apart from the ring.
            focusGap.isHidden = !hasFocus || look.fill.alpha < 1
            // The card's own color: the opaque surface under Reduce Transparency, else the glass.
            let onOpaqueCard = enclosingSurface?.material == .opaque
            focusGap.borderColor = (onOpaqueCard ? look.opaqueCard : look.card).nsColor.cgColor
            CATransaction.commit()
            alphaValue = isEnabled ? 1 : 0.45
            let font = button.role == .default ? Typography.bodyEmphasized : Typography.body
            if let keycapView {
                keycapView.paint(ink: look.title.nsColor, glyph: look.keyHint.nsColor)
                let title = NSMutableAttributedString(string: button.title, attributes: [.foregroundColor: look.title.nsColor, .font: font])
                if title.length > 0 {
                    title.addAttribute(.kern, value: keycapRoom(keycapView), range: NSRange(location: title.length - 1, length: 1))
                }
                attributedTitle = title
                invalidateIntrinsicContentSize()
                needsLayout = true
                return
            }
            attributedTitle = keyHint?.attributedTitle(button.title, font: font, color: look.title.nsColor, hintColor: look.keyHint.nsColor)
                ?? NSAttributedString(string: button.title, attributes: [.foregroundColor: look.title.nsColor, .font: font])
        }
        invalidateIntrinsicContentSize()
    }
}

extension CmuxDialogButtonView {
    /// The room after the title for the gap and the keycap, less the leading inset: the title and this room,
    /// centered in the button, leave the leading inset before the title and the keycap's inset after the plate.
    fileprivate func keycapRoom(_ keycap: CmuxDialogKeycapView) -> CGFloat {
        let height = CmuxDialogMetrics.keycapButtonHeight - CmuxDialogMetrics.keycapInset * 2
        return max(0, CmuxDialogMetrics.keycapGap + keycap.width(forHeight: height) + CmuxDialogMetrics.keycapInset
            - CmuxDialogMetrics.keycapLeading)
    }
}

/// Sizes shared by every dialog.
@MainActor
enum CmuxDialogMetrics {
    static var buttonHeight: CGFloat { 26 * Typography.userScale }
    static var buttonMinWidth: CGFloat { 72 * Typography.userScale }
    static var buttonCornerRadius: CGFloat { 7 }
    static var padding: CGFloat { Metrics.space5 }
    /// The dialog card (``CmuxDialogView``): its width, wider with an icon so the text column keeps its width.
    static var width: CGFloat { 380 * Typography.userScale }
    static var widthWithIcon: CGFloat { 432 * Typography.userScale }
    static var cardPadding: CGFloat { 16 * Typography.userScale }
    static var spacing: CGFloat { 8 * Typography.userScale }
    static var subtitleGap: CGFloat { 4 * Typography.userScale }
    static var buttonsGap: CGFloat { 12 * Typography.userScale }
    static var fieldHeight: CGFloat { 24 * Typography.userScale }
    static var iconSize: CGFloat { 40 * Typography.userScale }
    static var iconGap: CGFloat { 12 * Typography.userScale }
    /// A message past these many lines or characters scrolls in a box this tall, so the buttons stay on screen.
    static var linesMaxHeight: CGFloat { 240 * Typography.userScale }
    static let scrollingLineCount = 8
    static let scrollingCharacterCount = 600
    /// A keyed card button: taller and rounder, with the keycap plate one inset from its top, bottom and end.
    static var keycapButtonHeight: CGFloat { 28 * Typography.userScale }
    static var keycapButtonCornerRadius: CGFloat { 9 * Typography.userScale }
    static var keycapInset: CGFloat { 5 * Typography.userScale }
    static var keycapPadding: CGFloat { 4 * Typography.userScale }
    static var keycapLeading: CGFloat { 12 * Typography.userScale }
    static var keycapGap: CGFloat { 8 * Typography.userScale }
}
