import CmuxNextDesign
import Foundation

/// The `theme` event a page-host chat gets (``AgentPageEvent/theme(_:surface:)``), one per view.
///
/// `applyTheme` runs on every move of the view (`viewDidMoveToWindow`), every New Tab adoption and every scope
/// change, and pushes only an event that differs from the last one the page got.
@MainActor
final class AgentPaneThemeEvents {
    /// Events built from their inputs (tests count them).
    private(set) var builds = 0

    /// The theme event for `tokens` on `surface`, in the caller's theme scope.
    func event(_ tokens: ThemeTokens, surface: SurfaceKind) -> AgentPageEvent? {
        builds += 1
        return AgentPageEvent.theme(tokens, surface: surface)
    }
}
