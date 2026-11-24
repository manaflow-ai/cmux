public import AppKit
import CmuxNextDesignTokens

/// A table row whose selection is the theme's selection fill, never the system accent (cx-wqn5):
/// selected rows in dialogs and lists read like the sidebar's and the palette's. Never emphasized,
/// so the row's text keeps its own color instead of turning white on blue.
public final class ThemedTableRowView: NSTableRowView {
    /// How far the selection sits in from the row's sides, beyond the usual `space1` (a plain-style list whose
    /// content is inset, as New Message's under To:, keeps its highlight inside the panel's edges).
    public var selectionInset: CGFloat = 0

    public convenience init(selectionInset: CGFloat) {
        self.init(frame: .zero)
        self.selectionInset = selectionInset
    }

    public override var isEmphasized: Bool {
        get { false }
        set {}
    }

    public override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: Metrics.space1 + selectionInset, dy: 1)
        performWithTheme { Palette.selectionFill }.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill() // radius-allow: a table row's selection, not a button
    }
}

/// A button in the theme's colors instead of the system accent (cx-wqn5), re-resolved in its view's
/// scope when it moves into a window and on every theme change. It draws as a cmux `normal` dialog
/// button (``CmuxDialogButtonLook``): the selection fill as its own bezel (``ThemedBezelButtonCell``),
/// and a title in the theme's primary ink moved toward its pole until it reads at 4.5:1 on that fill over
/// what is under the button (``NSView/buttonGround(_:)``: a see-through window over the worst desktop
/// too). Disabled, both dim and the title holds 3:1. AppKit's own pick over its tinted push bezel fell
/// to 2.8:1 on Hot Dog Stand, its faded disabled label under 2:1, and the theme's ink on its bezel over a
/// see-through window to 1.86:1 (NativeControlContrastAuditTests).
public class ThemedBezelButton: ClickableButton {
    /// The bezel color AppKit is given; runs inside `performWithTheme`. theme-scoped
    var themeBezel: NSColor { Palette.selectionFill }

    /// Whether the button draws its own fill (``ThemedBezelButtonCell``); a checkbox keeps AppKit's box.
    var drawsOwnBezel: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyTheme()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the button's own fill and its disabled title in the ink ``applyTitle()`` sets, not AppKit's faded label.
    public override class var cellClass: AnyClass? {
        get { ThemedBezelButtonCell.self }
        set {}
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// The key that presses this button in its sheet or panel (u2647), shown after the title
    /// as in every cmux dialog and bound as the button's key equivalent: Return, Escape or
    /// Command plus a character. nil shows and binds none.
    public var keyHint: CmuxDialogKeyHint? {
        didSet {
            keyEquivalent = keyHint?.keyEquivalent ?? ""
            keyEquivalentModifierMask = keyHint?.modifierMask ?? []
            setAccessibilityHelp(keyHint?.spokenName)
            applyTitle()
        }
    }

    /// The title without the keycap (what callers set and read).
    private var plainTitle = ""

    public override var title: String {
        get { plainTitle }
        set {
            plainTitle = newValue
            applyTitle()
        }
    }

    public override var isEnabled: Bool {
        didSet { applyTitle() }
    }

    public override var font: NSFont? {
        didSet { applyTitle() }
    }

    private func applyTheme() {
        bezelColor = performWithTheme { themeBezel }
        applyTitle()
    }

    private func applyTitle() {
        let (ink, hint) = performWithTheme { () -> (NSColor, NSColor) in
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            let ground = buttonGround(tokens)
            let cell = cell as? ThemedBezelButtonCell
            guard drawsOwnBezel else {
                // A checkbox's title stands on the ground itself.
                cell?.fills = nil
                let base = (isEnabled ? tokens.textPrimary : tokens.textTertiary).composited(over: ground[0])
                let minimum = isEnabled ? CmuxDialogButtonLook.minimumContrast : CmuxDialogButtonLook.disabledMinimumContrast
                let ink = CmuxDialogButtonLook.readable(base, over: ground, minimum: minimum).nsColor
                return (ink, ink)
            }
            let rest = CmuxDialogButtonLook(role: .normal, tokens: tokens, isEnabled: isEnabled, card: ground)
            // AppKit keeps the title's ink while the button is held, so the press is the look's small hover step:
            // fit to the deeper pressed fill as well, the title flipped to black on Grass's green (4.30:1 at rest).
            let pressed = CmuxDialogButtonLook(role: .normal, tokens: tokens, state: .hover, isEnabled: isEnabled, card: ground)
            cell?.fills = (rest.fill.nsColor, pressed.fill.nsColor)
            return (rest.title.nsColor, rest.keyHint.nsColor)
        }
        needsDisplay = true
        guard !plainTitle.isEmpty || keyHint != nil else { return super.title = plainTitle }
        let font = self.font ?? Typography.body
        attributedTitle = keyHint?.attributedTitle(plainTitle, font: font, color: ink, hintColor: hint)
            ?? NSAttributedString(string: plainTitle, attributes: [.foregroundColor: ink, .font: font])
        setAccessibilityLabel(plainTitle)
    }
}

/// A dialog's Return (default) button in its scope's selection fill.
public final class ThemedDefaultButton: ThemedBezelButton {}

/// A checkbox (`ThemedCheckbox(checkboxWithTitle:target:action:)`) checked in the theme's ink, as
/// onboarding's are.
public final class ThemedCheckbox: ThemedBezelButton {
    override var themeBezel: NSColor { Palette.textPrimary }
    override var drawsOwnBezel: Bool { false }
}
