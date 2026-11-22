public import AppKit

/// The small built-in cmux wordmark, as text in the accent color. The empty-workspace splash
/// shows it above its title.
///
/// Keep this as plain text so it stays crisp in the terminal-style face and can
/// become the first entry in the future `cmux art` gallery without changing the
/// splash layout. The slant wordmark was the clear winner of the light/dark
/// pairwise vote recorded on #15245.
///
/// It applies its own color in its theme scope, in the hooks a theme change runs again
/// (`viewDidChangeEffectiveAppearance`, `viewDidMoveToWindow`), so its host only places it.
public final class CmuxWordmarkLabel: NSTextField {
    public static let wordmark = """
     ___ _ __ ___  _   ___
    / __| '_ ` _ \\| | | \\
    \\__ \\ | \\ | | |_| |
    |___/_| |_| |_|\\__,_|
    """

    public convenience init() {
        self.init(wrappingLabelWithString: Self.wordmark)
        font = Typography.system(.monospaced, size: Typography.title.pointSize, weight: TypeScale.emphasis)
        alignment = .center
        usesSingleLineMode = false
        maximumNumberOfLines = 0
        lineBreakMode = .byClipping
        setAccessibilityLabel("cmux")
        applyColor()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColor()
    }

    private func applyColor() {
        performWithTheme { textColor = Palette.accent }
    }
}
