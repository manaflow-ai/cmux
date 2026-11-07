public import AppKit
import CmuxTheme

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

    /// The same text colour in `tokens`.
    func rgb(_ tokens: ThemeTokens) -> ThemeRGB {
        switch self {
        case .primary: tokens.textPrimary
        case .secondary: tokens.textSecondary
        case .tertiary: tokens.textTertiary
        case .danger: tokens.danger
        }
    }

    /// The least contrast it reads at: a tertiary hint as a mark (3:1), the rest as text (4.5:1).
    var minimumContrast: Double { self == .tertiary ? ThemeTokens.minimumMarkContrast : ThemeTokens.minimumTextContrast }
}

/// A label whose text color follows its theme scope (room, workspace):
/// the color is read inside `performWithTheme` whenever the label joins a
/// window, shows or the theme changes, so it is never frozen at creation.
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

    // A theme change does not reach a hidden view (a toast's detail until Details shows it), so
    // the color is read again when the label shows.
    override public func viewDidUnhide() {
        super.viewDidUnhide()
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

    // As `ThemedLabel`: a theme change does not reach a hidden view.
    override public func viewDidUnhide() {
        super.viewDidUnhide()
        applyThemeTint()
    }

    private func applyThemeTint() {
        guard themeTint != nil || ink != nil else { return }
        performWithTheme { contentTintColor = themeTint?() ?? ink?.color }
    }
}
