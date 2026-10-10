import AppKit
import CmuxNextIcons
import CmuxNextPages
import CmuxNextUpdater

extension InternalPageID {
    static let changelog = InternalPageID(rawValue: "changelog")
}

/// The React changelog page (R114) as an internal page tab, one per window.
/// Opened by "What's New in cmux" (palette, menu, CLI) and the what's-new card.
@MainActor
final class ChangelogPageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]
    /// The route the next page view opens on (``open(_:focus:from:to:)``).
    private var pendingRoute: String?

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .changelog }
    var title: String { ChangelogPageStrings.title }
    var symbol: String { "sparkles" }
    var icon: IconName? { .fileText }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let route = pendingRoute
        pendingRoute = nil
        guard let services, let view = PageFactory(services: services).changelogPage(route: route) else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
    }

    /// Opens (or selects) the changelog tab in the active window. With `to` (an update's new
    /// version, and `from` its previous one) the page highlights the releases after `from` up to
    /// `to`, and says "Updated to <to>" when that span has no notes (`#/?from=<v>&to=<v>`).
    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true, from: String? = nil, to: String? = nil) -> Bool {
        let provider = services.pages.provider(.changelog) as? ChangelogPageTab ?? {
            let made = ChangelogPageTab(services: services)
            services.pages.register(made)
            return made
        }()
        let route = Self.route(from: from, to: to)
        provider.pendingRoute = route
        let view = services.pages.show(.changelog, in: services.windows.active, focus: focus)
        provider.pendingRoute = nil
        // An open tab moves to the new span.
        if let route, let page = view?.content as? PageWebView, page.route != route { page.open(route: route) }
        return view != nil
    }

    /// `#/?from=<from>&to=<to>`, nil without `to`.
    static func route(from: String?, to: String?) -> String? {
        guard let to, !to.isEmpty else { return nil }
        var query = URLComponents()
        query.queryItems = [from.flatMap { $0.isEmpty ? nil : URLQueryItem(name: "from", value: $0) },
                            URLQueryItem(name: "to", value: to)].compactMap { $0 }
        // URLSearchParams reads `+` as a space; a version may carry build metadata (`1.2.3+abc`).
        return "#/?" + (query.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}

nonisolated enum ChangelogPageStrings {
    static var title: String { String(localized: "changelog.page.title", defaultValue: "What's New", table: "Handlers", bundle: .module) }
}

extension PageFactory {
    /// The changelog page: `cmux.changelog.` to verified notes, `cmux.app.` to the native ops
    /// (Try it runs only the descriptor's allow-listed actions).
    func changelogPage(route: String? = nil) -> PageWebView? {
        let updater = services.updater
        let provider = ChangelogPageProvider(source: updater.releaseNotes, currentBuild: updater.identity.build)
        let native = AppPageNativeProvider(services: services, page: .changelog)
        let routes = [PageRoute(prefix: "cmux.changelog.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        let page = PageWebView(descriptor: .changelog, routes: routes, route: route)
        native.anchor = { [weak page] in page }
        return page
    }
}
