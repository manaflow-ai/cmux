public import AppKit
import CmuxNextDesignTokens

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
    /// Whether the title shows the key hint at all (a keyed button whose style shows no key for its role does not).
    private let drawsHint: Bool
    private var tracking: NSTrackingArea?
    /// Whether the focus ring shows: this button has keyboard focus, or the SwiftUI button it draws for has
    /// (``isFace``).
    var hasFocus = false { didSet { if hasFocus != oldValue { refresh() } } }
    /// Draws a SwiftUI `Button` (``CmuxDialogButtonStyle``): SwiftUI takes the clicks, the keys and the focus, so
    /// this view never does.
    var isFace = false
    /// The keyboard focus ring, just outside the button.
    private let focusRing = CALayer()
    /// On a solid fill, a line of the card's color just inside the button's edge, between the fill and
    /// the ring, so the ring reads apart from a fill of its own color (the accent default button).
    private let focusGap = CALayer()
    /// The key drawn on a plate at the trailing end (a cmux dialog's card), instead of as text after the title.
    private let keycapView: CmuxDialogKeycapView?
    /// How a keyed button draws its key (``CmuxDialogKeycapStyle``): the Linear-style hint every dialog draws
    /// (Lawrence 2026-11-16) unless the Keycap Playground shows another.
    let keycapStyle: CmuxDialogKeycapStyle
    /// Draws the button in this state whatever the pointer does (the Keycap Playground's hover and pressed rows).
    var previewState: CmuxDialogButtonLook.State? { didSet { refresh() } }
    /// The button's corner: rounder with a keycap, so the plate inside keeps one inset all round.
    private var cornerRadius: CGFloat {
        keycapView == nil ? CmuxDialogMetrics.buttonCornerRadius : CmuxDialogMetrics.keycapButtonCornerRadius
    }

    /// A button drawing `hint` after its title. The hint only labels the key: the host
    /// answers it (the overlay page's dialog through ``CmuxDialogKeys``), so pass the hint that
    /// ``CmuxDialogKeys/hint(for:in:)`` gives for the host's spec. `keycap` draws the hint on a plate at the
    /// button's trailing end (the cmux dialog card, ``CmuxDialogView``), on a taller, rounder button.
    public convenience init(_ button: CmuxDialogButton, hint: CmuxDialogKeyHint?, quiet: Bool = false, keycap: Bool = false,
                            target: AnyObject?, action: Selector) {
        self.init(button, hint: hint, quiet: quiet, keycap: keycap, keycapStyle: .linearKbd, target: target, action: action)
    }

    /// A keyed button drawing its key in `keycapStyle` (the Keycap Playground); a style that shows no key for this
    /// button's role (``CmuxDialogKeycapStyle/showsKey(for:)``) draws the title alone.
    init(_ button: CmuxDialogButton, hint: CmuxDialogKeyHint?, quiet: Bool = false, keycap: Bool,
         keycapStyle: CmuxDialogKeycapStyle, target: AnyObject?, action: Selector) {
        self.button = button
        keyHint = hint
        isQuiet = quiet
        self.keycapStyle = keycapStyle
        drawsHint = !keycap || keycapStyle.showsKey(for: button.role)
        keycapView = keycap && keycapStyle.showsKey(for: button.role) ? hint.map { CmuxDialogKeycapView($0.glyph, style: keycapStyle) } : nil
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
        isEnabled = button.isEnabled
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

    public override class var cellClass: AnyClass? {
        get { OwnInkButtonCell.self }
        set {}
    }

    public override var isEnabled: Bool { didSet { refresh() } }

    /// Shows a new title in place (Copy Link turning into "Copied").
    public func retitle(_ title: String) {
        guard title != button.title else { return }
        button.title = title
        setAccessibilityLabel(title)
        refresh()
    }

    public override var acceptsFirstResponder: Bool { !isFace }
    public override var canBecomeKeyView: Bool { !isFace }

    public override func hitTest(_ point: NSPoint) -> NSView? { isFace ? nil : super.hitTest(point) }
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
            let height = keycapView.height(inButton: bounds.height)
            let width = keycapView.width(forHeight: height)
            keycapView.frame = NSRect(x: bounds.maxX - keycapStyle.trailing - width, y: (bounds.height - height) / 2,
                                      width: width, height: height)
        }
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
        let state: CmuxDialogButtonLook.State = previewState ?? (isHighlighted ? .pressed : isHovering ? .hover : .rest)
        return performWithTheme {
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            // A quiet button is a destructive one, or a stacked request's Deny (its cancel answer) in the same red text.
            // On a menu or popover's glass (the bookmark bubble) the page shows through unscrimmed: fit to any page.
            // Outside any card the button sits on the window, see-through or not.
            return CmuxDialogButtonLook(role: isQuiet ? .destructive : button.role, tokens: tokens, state: state, quiet: isQuiet,
                                        isEnabled: isEnabled, card: buttonGround(tokens))
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
            let onOpaqueCard = enclosingOverlaySurface?.material == .opaque
            focusGap.borderColor = (onOpaqueCard ? look.opaqueCard : look.card).nsColor.cgColor
            CATransaction.commit()
            let font = button.role == .default ? Typography.cardTitle : Typography.cardMessage
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
            attributedTitle = (drawsHint ? keyHint : nil)?.attributedTitle(button.title, font: font, color: look.title.nsColor, hintColor: look.keyHint.nsColor)
                ?? NSAttributedString(string: button.title, attributes: [.foregroundColor: look.title.nsColor, .font: font])
        }
        invalidateIntrinsicContentSize()
    }
}

extension CmuxDialogButtonView {
    /// The room after the title for the gap and the keycap, less the leading inset: the title and this room,
    /// centered in the button, leave the leading inset before the title and the keycap's inset after the plate.
    fileprivate func keycapRoom(_ keycap: CmuxDialogKeycapView) -> CGFloat {
        let height = keycap.height(inButton: CmuxDialogMetrics.keycapButtonHeight)
        return max(0, keycap.style.gap + keycap.width(forHeight: height) + keycap.style.trailing - CmuxDialogMetrics.keycapLeading)
    }
}

/// Sizes shared by every dialog.
@MainActor
enum CmuxDialogMetrics {
    static var buttonHeight: CGFloat { 26 * Typography.userScale }
    static var buttonMinWidth: CGFloat { 72 * Typography.userScale }
    /// A dialog button rounds as a tab (`Metrics.buttonCornerRadius`; Lawrence 2026-11-12).
    static var buttonCornerRadius: CGFloat { Metrics.buttonCornerRadius }
    static var padding: CGFloat { Metrics.space5 }
    /// The dialog card (``CmuxDialogView``): its width, wider with an icon so the text column keeps its width.
    static var width: CGFloat { 380 * Typography.userScale }
    static var widthWithIcon: CGFloat { 432 * Typography.userScale }
    /// The card's padding: the density's dialog padding (``Metrics/dialogPadding``, 16 pt at Default; #49579).
    static var cardPadding: CGFloat { Metrics.dialogPadding }
    /// The card's concentric geometry (Lawrence 2026-11-15: "all dialogs needs concentric padding with buttons
    /// inside"): the buttons on its bottom row sit ``cardPadding`` from the bottom and the sides, so the card
    /// rounds by the button corner plus that padding.
    static var card: ConcentricContainer { Metrics.buttonContainer(padding: cardPadding) }
    static var spacing: CGFloat { Metrics.space4 }
    static var subtitleGap: CGFloat { Metrics.space2 }
    static var buttonsGap: CGFloat { 12 * Typography.userScale }
    static var fieldHeight: CGFloat { 24 * Typography.userScale }
    static var iconSize: CGFloat { 40 * Typography.userScale }
    static var iconGap: CGFloat { 12 * Typography.userScale }
    /// A floating prompt's header icon, beside its title.
    static var headerIconSize: CGFloat { 20 * Typography.userScale }
    static var headerIconGap: CGFloat { 8 * Typography.userScale }
    /// A message past these many lines or characters scrolls in a box this tall, so the buttons stay on screen.
    static var linesMaxHeight: CGFloat { 240 * Typography.userScale }
    static let scrollingLineCount = 8
    static let scrollingCharacterCount = 600
    /// A keyed card button: taller and rounder, with the keycap plate one inset from its top, bottom and end.
    /// A keyed button is as tall as an unkeyed one and rounds as every button does (Lawrence 2026-11-15: a keyed and
    /// an unkeyed button side by side match).
    static var keycapButtonHeight: CGFloat { buttonHeight }
    static var keycapButtonCornerRadius: CGFloat { Metrics.buttonCornerRadius }
    /// The chip's inset on its top, bottom and trailing side: small, so the chip keeps a round corner (the button's
    /// less this; at 5 pt it was 3 pt and about 1 pt at compact, and read square).
    static var keycapInset: CGFloat { 3 * Typography.userScale }
    /// The keycap in its button (Lawrence 2026-11-15: the chips round concentrically with their button): the
    /// button's corner, the chip's corner that less ``keycapInset``.
    static var keycap: ConcentricContainer { ConcentricContainer(outerRadius: keycapButtonCornerRadius, padding: keycapInset) }
    /// The smallest chip corner that still reads round, where the button's corner less the inset is less.
    static let keycapCornerFloor: CGFloat = 2
    /// The chip's corner on a chip `size` big: concentric with the button, at least ``keycapCornerFloor``, at most
    /// half its height.
    static func keycapCornerRadius(fitting size: CGSize) -> CGFloat {
        min(max(keycap.childRadius(fitting: size), keycapCornerFloor), min(size.width, size.height) / 2)
    }
    static var keycapPadding: CGFloat { 4 * Typography.userScale }
    static var keycapLeading: CGFloat { 12 * Typography.userScale }
    static var keycapGap: CGFloat { 8 * Typography.userScale }
    /// A code's well (``CmuxDialogCodeWell``): the code this far in from its sides, and from its top and bottom.
    static var codeInset: CGFloat { 10 * Typography.userScale }
    static var codeVerticalInset: CGFloat { 7 * Typography.userScale }
    /// The well's fill and edge: the text's ink at these alphas.
    static let codeWellFill: CGFloat = 0.06
    static let codeWellEdge: CGFloat = 0.12
    /// One device pixel in `window` (1 pt on a 1x screen).
    static func hairline(in window: NSWindow?) -> CGFloat { 1 / max(window?.backingScaleFactor ?? 2, 1) }
}
