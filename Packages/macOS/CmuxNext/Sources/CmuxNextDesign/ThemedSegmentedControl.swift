public import AppKit

/// A segmented control whose selected segment is the theme's selection fill
/// (`Palette.selectionFill`) instead of the system's, re-resolved in its scope when it moves into a
/// window and on every theme change. Keys and VoiceOver are the stock control's.
public final class ThemedSegmentedControl: NSSegmentedControl {
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        selectedSegmentBezelColor = performWithTheme { Palette.selectionFill }
    }
}
