import AppKit
import CmuxNextControl
import CmuxNextHibernation
import CmuxNextPages

// The view state of a page tab that shows a React page (Settings, Keyboard Shortcuts, the
// changelog): the place it shows, its URL fragment. Chrome keeps a discarded tab's navigation entry
// with its URL and gives it back on reload (content/public/browser/navigation_entry.h); a cmux
// page's place is its fragment, which moves with the page's own links, so it is read from the
// document right before the view goes.
extension PageWebView {
    /// The ``ContentViewState/values`` key of the saved fragment.
    static let discardRouteKey = "route"

    /// What this page shows, for a discard of its tab: the fragment the document shows now, read
    /// within 2 s (the last one the host asked for when the document does not answer).
    func discardViewState() async -> ContentViewState {
        let shown: String?
        do {
            shown = try await ControlDeadline.shared.run(method: "pages.discard.route", deadline: .now + .seconds(2)) { @MainActor in
                await self.shownRoute()
            }
        } catch {
            shown = route
        }
        var state = ContentViewState()
        state.values[Self.discardRouteKey] = shown
        return state
    }

    /// Shows the place `state` saved on this page, built again for a discarded tab. A page whose
    /// show asked for a place (``route`` set: Settings on a section, What's New on a release span)
    /// stays on it.
    func restoreDiscardViewState(_ state: ContentViewState) {
        guard route == nil, let saved = state.values[Self.discardRouteKey] else { return }
        open(route: saved)
    }
}
