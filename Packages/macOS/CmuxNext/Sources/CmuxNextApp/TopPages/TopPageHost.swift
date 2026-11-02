import AppKit
import CmuxNextHomeEngine

/// One window's top pages: one view per route, made on first show and kept
/// for the window's life, so a page keeps its state (scroll, search, the
/// composer draft) when the window switches to a workspace and back. Page
/// models stay shared through their providers.
@MainActor
final class TopPageHost {
    private weak var services: AppServices?
    private(set) var views: [TopPageRoute: NSView] = [:]
    /// The provider key of each internal page view (a `LocalPageTab` key,
    /// so providers that read the key keep working).
    private var keys: [TopPageRoute: String] = [:]

    init(services: AppServices) {
        self.services = services
    }

    /// The page's view, made on first show; nil when no provider serves the route.
    func view(for route: TopPageRoute, in window: WindowController) -> NSView? {
        guard let services else { return nil }
        if case .page(let id) = route, InternalPageTabStore.isPreviewPage(id),
           services.settings?.snapshot.previewFeatures != true { return nil }
        if let view = views[route] { return view }
        let view: NSView
        switch route {
        case .home:
            // The docked Home (cx-ebm.59.5) is the home workspace itself; only classic Home is a top page.
            guard HomeDock.classic else { return nil }
            view = TopHomePageView(services: services, windowKey: { [weak window] in window?.state.id ?? "" })
        case .page(let id):
            guard let provider = TopPages.provider(id, services: services) else { return nil }
            let key = LocalPageTab.makeKey(id)
            keys[route] = key
            let content = provider.makeView(for: key, in: window)
            let page = InternalPageView(key: key, page: id, content: content, topBar: provider.makeTopBar(for: key))
            page.navigate = services.pages.navigate
            view = page
        }
        views[route] = view
        return view
    }

    /// The provider key of `route`'s view, once made.
    func key(for route: TopPageRoute) -> String? { keys[route] }

    /// The page's title for the titlebar.
    func title(for route: TopPageRoute) -> String {
        switch route {
        case .home: HomeStrings.title
        case .page(let id): services?.pages.provider(id)?.title ?? ""
        }
    }

    /// Gives the page's primary input the keyboard (Home: the message box;
    /// a React page: its web content).
    func focus(_ route: TopPageRoute, in window: NSWindow?) {
        switch views[route] {
        case let home as TopHomePageView: home.focusPrimaryInput()
        case let page as InternalPageView: window?.makeFirstResponder(page.focusTarget)
        default: break
        }
    }

    /// The window closed: every page view goes, and providers forget them.
    func teardown() {
        for (route, view) in views {
            view.removeFromSuperview()
            // The key goes first, so the provider no longer counts this page as open (`pageIsOpen`).
            if case .page(let id) = route, let key = keys.removeValue(forKey: route) { services?.pages.provider(id)?.tabClosed(key) }
        }
        views.removeAll()
        keys.removeAll()
    }
}
