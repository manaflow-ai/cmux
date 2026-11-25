public import AppKit
import CmuxNextDesignTokens

/// A pop-up button drawn as ``ThemedBezelButton`` is, instead of macOS's gray: the theme's selection fill
/// as its own bezel with its chevron, and its title in the theme's primary ink fit to 4.5:1 on that fill
/// over what is under it (3:1 while disabled; ``CmuxDialogButtonLook`` `normal`). AppKit's own label ink
/// follows the window's light or dark appearance, not the theme: on a mid-tone theme's selection fill it
/// read at 3.57:1 (Blue Dolphin), its disabled label under 2:1, and on its bezel over a see-through
/// window 1.94:1 (NativeControlContrastAuditTests).
public final class ThemedPopUpButton: NSPopUpButton {
    public override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        applyTheme()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override class var cellClass: AnyClass? {
        get { ThemedPopUpButtonCell.self }
        set {}
    }

    public override var isEnabled: Bool {
        didSet { applyTheme() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let (bezel, look) = performWithTheme { () -> (NSColor, CmuxDialogButtonLook) in
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            return (Palette.selectionFill, CmuxDialogButtonLook(role: .normal, tokens: tokens, isEnabled: isEnabled, card: buttonGround(tokens)))
        }
        bezelColor = bezel
        let cell = cell as? ThemedPopUpButtonCell
        cell?.fill = look.fill.nsColor
        cell?.ink = look.title.nsColor
        needsDisplay = true
    }
}
