import AppKit

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
        if let view = views[route] { return view }
        guard let services else { return nil }
        let view: NSView
        switch route {
        case .home:
            view = TopHomePageView(services: services)
        case .page(let id):
            guard let provider = TopPages.provider(id, services: services) else { return nil }
            let key = LocalPageTab.makeKey(id)
            keys[route] = key
            view = InternalPageView(key: key, page: id, content: provider.makeView(for: key, in: window))
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
            if case .page(let id) = route, let key = keys[route] { services?.pages.provider(id)?.tabClosed(key) }
        }
        views.removeAll()
        keys.removeAll()
    }
}
