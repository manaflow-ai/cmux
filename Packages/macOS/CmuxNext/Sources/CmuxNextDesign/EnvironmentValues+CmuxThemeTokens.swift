public import SwiftUI
public import CmuxNextDesignTokens

extension EnvironmentValues {
    /// The theme tokens of the AppKit scope a SwiftUI subtree is hosted in, for styles that draw
    /// theme colors (``CmuxDialogButtonStyle``); nil until the host sets them, when such a style
    /// draws in the app theme (`ThemeTokens.unresolved`).
    @Entry public var cmuxThemeTokens: ThemeTokens?
}

extension View {
    /// Hands `tokens` (the host view's scope, resolved in `performWithTheme`) to the theme-drawn
    /// styles below, as ``SwiftUICore/EnvironmentValues/cmuxThemeTokens``.
    /// - Parameter tokens: The tokens the subtree's styles draw with.
    public func cmuxThemeTokens(_ tokens: ThemeTokens) -> some View {
        environment(\.cmuxThemeTokens, tokens)
    }
}
