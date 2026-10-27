public import AppKit

/// A pop-up button whose bezel is the theme's selection fill, as `ThemedBezelButton`'s is, instead
/// of macOS's gray.
public final class ThemedPopUpButton: NSPopUpButton {
    public override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        applyTheme()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    // visibility-walk-allow: one bezel color store; cheaper than a deferral
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        bezelColor = performWithTheme { Palette.selectionFill }
    }
}
