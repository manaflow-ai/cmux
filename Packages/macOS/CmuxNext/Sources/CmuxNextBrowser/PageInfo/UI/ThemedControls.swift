import AppKit
import CmuxNextDesign

/// A label whose text color follows its theme scope (room, workspace):
/// `themeColor` runs inside `performWithTheme` whenever the label joins a
/// window or the theme changes, so the color is never frozen at creation.
final class ThemedLabel: NSTextField {
    var themeColor: () -> NSColor = { NSColor.labelColor } {
        didSet { applyThemeColor() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColor()
    }

    private func applyThemeColor() {
        performWithTheme { textColor = themeColor() }
    }
}

/// An image view whose tint follows its theme scope, like `ThemedLabel`.
final class ThemedImageView: NSImageView {
    var themeTint: (() -> NSColor)? {
        didSet { applyThemeTint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeTint()
    }

    private func applyThemeTint() {
        guard let themeTint else { return }
        performWithTheme { contentTintColor = themeTint() }
    }
}
