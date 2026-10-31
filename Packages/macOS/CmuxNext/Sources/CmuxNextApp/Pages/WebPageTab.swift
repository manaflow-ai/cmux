import AppKit
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
    private let make: (String) -> NSView?
    private var pages: [String: NSView] = [:]

    convenience init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String, make: @escaping () -> PageWebView?) {
        self.init(page, symbol: symbol, icon: icon, title: title, view: { _ in make() })
    }

    /// A page whose tabs are native views made per tab `key` (the native New Tab page).
    init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String, view make: @escaping (String) -> NSView?) {
        self.page = page
        self.symbol = symbol
        self.icon = icon
        self.title = title
        self.make = make
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let view = make(key) else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { (pages.removeValue(forKey: key) as? PageWebView)?.close() }
}
