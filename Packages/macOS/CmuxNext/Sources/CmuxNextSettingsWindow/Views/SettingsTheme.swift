import AppKit
import CmuxNextDesign
import Observation

/// The theme the Debug Settings views draw in: the `ThemeScope` of the main
/// window they were opened from (the App sets it), else the app theme.
/// SwiftUI would resolve `Color(nsColor: Palette.x)` against the app theme,
/// so `SettingsStyle` is made from these tokens instead; views re-render
/// through Observation when they change. Owned by ``DebugSettingsModel``
/// (``DebugSettingsModel/theme``): one per model, never process-wide.
@MainActor
@Observable
final class SettingsTheme: ThemeResponsive {
    private(set) var tokens: ThemeTokens
    private(set) var input: ThemeInput
    @ObservationIgnored private(set) var scope: ThemeScope

    init() {
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
