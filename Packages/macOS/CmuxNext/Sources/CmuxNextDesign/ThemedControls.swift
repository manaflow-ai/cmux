public import AppKit

/// A table row whose selection is the theme's selection fill, never the system accent (cx-wqn5):
/// selected rows in dialogs and lists read like the sidebar's and the palette's. Never emphasized,
/// so the row's text keeps its own color instead of turning white on blue.
public final class ThemedTableRowView: NSTableRowView {
    public override var isEmphasized: Bool {
        get { false }
        set {}
    }

    public override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: Metrics.space1, dy: 1)
        performWithTheme { Palette.selectionFill }.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill() // radius-allow: a table row's selection, not a button
    }
}

/// A button whose bezel is a theme color instead of the system accent (cx-wqn5), re-resolved in
/// its view's scope when it moves into a window and on every theme change. Its title draws in the
/// theme's ink, never AppKit's: primary text, which holds 4.5:1 on the selection fill in every theme
/// (AppKit's own pick over a tinted bezel fell to 2.8:1 on Hot Dog Stand), and the tertiary text
/// while disabled, which holds the legible floor where AppKit's faded label fell under 2:1
/// (NativeControlContrastAuditTests).
public class ThemedBezelButton: ClickableButton {
    /// The bezel; runs inside `performWithTheme`. theme-scoped
    var themeBezel: NSColor { Palette.selectionFill }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyTheme()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        guard !plainTitle.isEmpty || keyHint != nil else { return super.title = plainTitle }
        let font = self.font ?? Typography.body
        attributedTitle = performWithTheme {
            let ink = isEnabled ? Palette.textPrimary : Palette.textTertiary
            return keyHint?.attributedTitle(plainTitle, font: font, color: ink)
                ?? NSAttributedString(string: plainTitle, attributes: [.foregroundColor: ink, .font: font])
        }
        setAccessibilityLabel(plainTitle)
    }
}

/// A dialog's Return (default) button in its scope's selection fill.
public final class ThemedDefaultButton: ThemedBezelButton {}

/// A checkbox (`ThemedCheckbox(checkboxWithTitle:target:action:)`) checked in the theme's ink, as
/// onboarding's are.
public final class ThemedCheckbox: ThemedBezelButton {
    override var themeBezel: NSColor { Palette.textPrimary }
}
