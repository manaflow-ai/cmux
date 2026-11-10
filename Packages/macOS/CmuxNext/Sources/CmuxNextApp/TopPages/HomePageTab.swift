import AppKit
import CmuxNextHome
import CmuxNextHomeEngine

extension InternalPageID {
    /// The native Home as a pane tab (`home.tab`). Its own id: the Home top
    /// page is a `TopPageRoute`, never a page tab.
    static let homeTab = InternalPageID(rawValue: "home-tab")
}

/// Home's Messages page (``HomeMessagesPage``, the React `home-messages` page) as an internal page tab, so it sits in a split next to any other tab, the
/// channels Home among them. Every tab reads the one `HomeService`
/// (`services.home`): a message sent in one Home shows in every other Home
/// at once. Each `home.tab` run opens one more tab; each tab has its own
/// list selection, composer draft and width. The Home top page
/// (`home.show`) stays as it is.
@MainActor
final class HomePageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var views: [String: HomeMessagesPage] = [:]
    /// The order the tabs opened in (`debug.home` lists them so).
    private var order: [String] = []

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .homeTab }
    var title: String { HomeStrings.title }
    var symbol: String { "house" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        guard let view = HomeMessagesPage.make(services: services, widthKey: "home-tab") else { return NSView() }
        views[key] = view
        order.append(key)
        return view
    }

    func tabClosed(_ key: String) {
        views.removeValue(forKey: key)?.close()
        order.removeAll { $0 == key }
    }

    /// Open Home tabs by provider key, in the order they opened.
    var tabs: [(key: String, view: HomeMessagesPage)] {
        order.compactMap { key in views[key].map { (key, $0) } }
    }

    /// `home.tab`: one more Home tab in the active window, after the focused
    /// pane's selected tab. A user run selects and focuses it (and leaves a
    /// top page); automation opens it without changing the view. False when
    /// the window has no pane to hold it.
    @discardableResult
    static func open(_ services: AppServices, focus: Bool) -> Bool {
        if services.pages.provider(.homeTab) == nil { services.pages.register(HomePageTab(services: services)) }
        return services.pages.openNew(.homeTab, in: services.windows.active, focus: focus) != nil
    }
}
