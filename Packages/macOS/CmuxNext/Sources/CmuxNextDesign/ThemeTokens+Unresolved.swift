public import CmuxTheme
public import SwiftUI
public import CmuxNextDesignTokens

extension ThemeTokens {
    /// The app theme's tokens now (`ThemeTokens.fallback` until the Ghostty config is read), from
    /// any thread. A color struct starts with them, so a frame drawn before its host resolves the
    /// view's own scope is in the theme every scope derives from, never in macOS's grays. Not a
    /// substitute for resolving in the view's scope.
    nonisolated public static var unresolved: ThemeTokens { ThemeSnapshot.tokens }
}

extension ThemeRGB {
    /// This color as a static SwiftUI color (it never re-resolves in SwiftUI's own appearance).
    nonisolated public var swiftUIColor: Color { Color(nsColor: nsColor) }
}
