public import AppKit

/// A text field for short-lived editors (inline renames) that keeps its
/// colors in its theme scope while it is open: a theme change repaints the
/// scope and calls `viewDidChangeEffectiveAppearance`, which re-applies the
/// field's colors and those of its active field editor (text, caret,
/// selection).
public final class ThemedTextField: NSTextField {
    /// The fill behind the text, resolved in the field's scope.
    public var fill: @MainActor () -> NSColor = { Palette.windowBackground }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        applyThemeColors()
        return became
    }

    public func applyThemeColors() {
        performWithTheme {
            backgroundColor = fill()
            textColor = Palette.textPrimary
            guard let editor = currentEditor() as? NSTextView else { return }
            editor.textColor = Palette.textPrimary
            editor.insertionPointColor = Palette.textPrimary
            editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
    }
}
