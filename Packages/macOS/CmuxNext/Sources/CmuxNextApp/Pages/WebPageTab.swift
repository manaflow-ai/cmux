import AppKit
import CmuxNextControl
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages

/// A React page as an internal page tab, one view per tab: `make` builds each tab's page with its
/// routes, and a closed tab closes its page. The Stats, Chief Usage, Chief view gallery, channels
/// and CodeRouter tabs are this; a page with routes or sub-views of its own has its own provider.
@MainActor
final class WebPageTab: InternalPageProvider {
    let page: InternalPageID
    let symbol: String
    let icon: IconName?
    /// Read once, when the tab registers: page titles do not change while the app runs.
    let title: String
    /// When a hidden tab's page may go (`memoryDiscardInternalPages`); its next show makes a new one.
    let policy: ContentDiscardPolicy
    private let make: () -> PageWebView?
    private var pages: [String: PageWebView] = [:]

    init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String,
         discardPolicy: ContentDiscardPolicy = .standard, make: @escaping () -> PageWebView?) {
        self.page = page
        self.symbol = symbol
        self.icon = icon
        self.title = title
        policy = discardPolicy
        self.make = make
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let view = make() else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }

    func discardPolicy(for key: String) -> ContentDiscardPolicy { policy }

    /// The tab's page went (the tab store closed it); the next view makes its own.
    func viewDiscarded(_ key: String) { pages.removeValue(forKey: key) }
}

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
