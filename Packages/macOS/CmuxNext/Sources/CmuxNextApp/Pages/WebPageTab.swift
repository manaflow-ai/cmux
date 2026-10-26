import AppKit
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
    /// When a hidden tab's page goes (`memoryDiscardInternalPages`); its next show makes a new one.
    let hiddenPolicy: ContentDiscardPolicy
    private let make: () -> PageWebView?
    private var pages: [String: PageWebView] = [:]

    init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String,
         hiddenPolicy: ContentDiscardPolicy = .standard, make: @escaping () -> PageWebView?) {
        self.page = page
        self.symbol = symbol
        self.icon = icon
        self.title = title
        self.hiddenPolicy = hiddenPolicy
        self.make = make
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let view = make() else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }

    func discardPolicy(for key: String) -> ContentDiscardPolicy { hiddenPolicy }

    /// The tab stays and its page goes (the page store ends its bridge).
    func viewDiscarded(_ key: String) { pages[key] = nil }

    /// Whether tab `key` has a page now (tests).
    func hasPage(_ key: String) -> Bool { pages[key] != nil }
}
