public import AppKit

/// A pop-up button whose bezel is the theme's selection fill, as `ThemedBezelButton`'s is, instead
/// of macOS's gray, and whose title draws in the theme's ink: primary text, tertiary while disabled.
/// AppKit's own label ink follows the window's light or dark appearance, not the theme: on a
/// mid-tone theme's selection fill it read at 3.57:1 (Blue Dolphin), and its disabled label under 2:1
/// (NativeControlContrastAuditTests).
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
        let (bezel, ink) = performWithTheme { (Palette.selectionFill, isEnabled ? Palette.textPrimary : Palette.textTertiary) }
        bezelColor = bezel
        (cell as? ThemedPopUpButtonCell)?.ink = ink
        needsDisplay = true
    }
}
