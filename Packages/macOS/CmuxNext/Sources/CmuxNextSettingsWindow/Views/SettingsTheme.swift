import AppKit
import CmuxNextDesign
import Observation

/// The theme the Settings window draws in: the `ThemeScope` of the main
/// window it was opened from (the App sets it), else the app theme.
/// SwiftUI would resolve `Color(nsColor: Palette.x)` against the app theme,
/// so `SettingsStyle` reads these tokens instead; views re-render through
/// Observation when they change.
@MainActor
@Observable
final class SettingsTheme: ThemeResponsive {
    /// One Settings window per app.
    static let shared = SettingsTheme()

    private(set) var tokens: ThemeTokens
    private(set) var input: ThemeInput
    @ObservationIgnored private(set) var scope: ThemeScope

    private init() {
        scope = .app
        tokens = ThemeScope.app.tokens
        input = ThemeScope.app.input
        ThemeScope.app.addResponder(self)
    }

    /// Follows `scope` from now on (its colors and later changes).
    func follow(_ scope: ThemeScope) {
        if scope !== self.scope {
            self.scope = scope
            scope.addResponder(self)
        }
        themeDidChange()
    }

    /// Scopes the window no longer follows keep this responder registered
    /// (weakly); their changes are ignored.
    func themeDidChange() {
        if tokens != scope.tokens { tokens = scope.tokens }
        if input != scope.input { input = scope.input }
    }
}
