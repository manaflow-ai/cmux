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
/// `themeColor` runs inside `performWithTheme` whenever the label joins a
/// window or the theme changes, so the color is never frozen at creation.
/// The theme's primary text by default; `Palette.textSecondary` for notes.
public final class ThemedLabel: NSTextField {
    public var themeColor: @MainActor () -> NSColor = { Palette.textPrimary } {
        didSet { applyThemeColor() }
    }

    /// One of the theme's text colors (sets `themeColor`).
    public var ink: ThemeInk = .primary {
        didSet { themeColor = { [ink] in ink.color } }
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
        performWithTheme { textColor = themeColor() }
    }
}

/// An image view whose tint follows its theme scope, like `ThemedLabel`.
public final class ThemedImageView: NSImageView {
    public var themeTint: (@MainActor () -> NSColor)? {
        didSet { applyThemeTint() }
    }

    /// One of the theme's text colors as the tint (sets `themeTint`).
    public var ink: ThemeInk? {
        didSet {
            guard let ink else { return themeTint = nil }
            themeTint = { ink.color }
        }
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
        guard let themeTint else { return }
        performWithTheme { contentTintColor = themeTint() }
    }
}
