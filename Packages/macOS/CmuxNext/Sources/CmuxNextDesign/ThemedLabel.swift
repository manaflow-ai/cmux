public import AppKit

/// The theme text color a label or glyph draws in, resolved in its scope.
public enum ThemeInk: Sendable {
    case primary, secondary, tertiary, danger

    /// theme-scoped
    @MainActor var color: NSColor {
        switch self {
        case .primary: Palette.textPrimary
        case .secondary: Palette.textSecondary
        case .tertiary: Palette.textTertiary
        case .danger: Palette.danger
        }
    }
}

/// A label whose text color follows its theme scope (room, workspace):
/// the color is read inside `performWithTheme` whenever the label joins a
/// window or the theme changes, so it is never frozen at creation.
public final class ThemedLabel: ChromeLabel {
    /// A style color read in the label's scope; nil draws `ink`.
    public var themeColor: (() -> NSColor)? {
        didSet { applyThemeColor() }
    }

    /// One of the theme's text colors, when `themeColor` is nil.
    public var ink: ThemeInk = .primary {
        didSet { applyThemeColor() }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColor()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColor()
    }

    private func applyThemeColor() {
        performWithTheme { textColor = themeColor?() ?? ink.color }
    }
}

/// An image view whose tint follows its theme scope, like `ThemedLabel`.
public final class ThemedImageView: NSImageView {
    /// A style color read in the view's scope; nil tints with `ink`.
    public var themeTint: (() -> NSColor)? {
        didSet { applyThemeTint() }
    }

    /// One of the theme's text colors, when `themeTint` is nil.
    public var ink: ThemeInk? {
        didSet { applyThemeTint() }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeTint()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeTint()
    }

    private func applyThemeTint() {
        guard themeTint != nil || ink != nil else { return }
        performWithTheme { contentTintColor = themeTint?() ?? ink?.color }
    }
}
