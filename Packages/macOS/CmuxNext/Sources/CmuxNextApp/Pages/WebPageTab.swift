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
    /// When a hidden tab's page may go (`memoryDiscardInternalPages`); its next show makes a new
    /// one. Never unless the page's owner chose a policy for it.
    let policy: ContentDiscardPolicy
    private let make: () -> PageWebView?
    private var pages: [String: PageWebView] = [:]

    init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String,
         discardPolicy: ContentDiscardPolicy = .never, make: @escaping () -> PageWebView?) {
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

    /// The tab stays and its page goes, closed as at ``tabClosed(_:)``: its routes, bridge and engine
    /// page end. The next show makes a new page.
    func viewDiscarded(_ key: String) { pages.removeValue(forKey: key)?.close() }

    /// Whether tab `key` has a page now (tests).
    func hasPage(_ key: String) -> Bool { pages[key] != nil }
}

/// The place (URL fragment) each discarded page tab showed, for the page its next show makes
/// (`memoryDiscardInternalPages`). Chrome keeps a discarded tab's navigation entry and reloads its
/// URL (content/public/browser/navigation_entry.h). A cmux page's place is its fragment, which
/// follows the page's own links, so ``PageWebView/route`` (the last fragment the host asked for)
/// is not it: the discard's preparation reads it from the document.
@MainActor
final class DiscardedPageRoutes {
    /// Tab key -> the fragment its document showed when the discard read it, with the page's
    /// ``InternalPageTabStore/pictureVersion(_:)`` then.
    private var reads: [String: (version: Int, fragment: String)] = [:]
    /// Tab key -> the fragment its next page opens on.
    private var routes: [String: String] = [:]

    /// The view state of tab `key`'s `page` for its discard: its document scroll (the provider
    /// default), and the fragment it shows, kept here for ``discarded(_:page:)``.
    func save(_ key: String, page: PageWebView) async -> ContentViewState {
        let version = InternalPageTabStore.pictureVersion(page)
        let scroll = await page.documentScroll()
        let fragment = await page.shownFragment()
        reads[key] = fragment.map { (version: version, fragment: $0) }
        return ContentViewState(scroll: scroll)
    }

    /// Tab `key`'s `page` goes: its next page opens on the fragment the discard read, unless the
    /// page changed since (the person's input, a new paint, a host route), then on ``PageWebView/route``.
    func discarded(_ key: String, page: PageWebView) {
        let read = reads.removeValue(forKey: key).flatMap { $0.version == InternalPageTabStore.pictureVersion(page) ? $0.fragment : nil }
        let fragment = read ?? page.route ?? ""
        routes[key] = fragment.isEmpty || fragment == "#" ? nil : fragment
    }

    /// The fragment tab `key`'s next page opens on, once; nil for the page's default place.
    func take(_ key: String) -> String? { routes.removeValue(forKey: key) }

    /// Tab `key` closed.
    func forget(_ key: String) {
        reads[key] = nil
        routes[key] = nil
    }
}

extension PageWebView {
    /// The fragment the document shows now (`window.location.hash`, empty on its default place),
    /// read within 2 s in either engine; nil when the document does not answer.
    func shownFragment() async -> String? {
        try? await ControlDeadline.shared.run(method: "pages.discard.fragment", deadline: .now + .seconds(2)) { @MainActor in
            await self.callPageFunction("return window.location.hash;") as? String
        }
    }
}
