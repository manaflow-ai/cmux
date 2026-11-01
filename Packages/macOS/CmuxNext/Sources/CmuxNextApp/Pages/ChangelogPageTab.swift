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

    /// The page's provider, registered once. The app registers it at launch:
    /// without it a restored What's New tab had no title (the strip showed
    /// the store tab's own, "Home") and no page (cx-warpr).
    @discardableResult
    static func register(_ services: AppServices) -> ChangelogPageTab {
        if let provider = services.pages.provider(.changelog) as? ChangelogPageTab { return provider }
        let made = ChangelogPageTab(services: services)
        services.pages.register(made)
        return made
    }

    /// Opens (or selects) the changelog tab in the active window. With `to` (an update's new
    /// version, and `from` its previous one) the page highlights the releases after `from` up to
    /// `to`, and says "Updated to <to>" when that span has no notes (`#/?from=<v>&to=<v>`).
    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true, from: String? = nil, to: String? = nil) -> Bool {
        let provider = register(services)
        let route = Self.route(from: from, to: to, design: WhatsNewTunables.design.value)
        provider.pendingRoute = route
        let view = services.pages.show(.changelog, in: services.windows.active, focus: focus)
        provider.pendingRoute = nil
        // An open tab moves to the new span (a design change alone applies the next time the page opens).
        if let route, to?.isEmpty == false, let page = view?.content as? PageWebView, page.route != route { page.open(route: route) }
        return view != nil
    }

    /// `#/?design=<d>&from=<from>&to=<to>`: `design` only off the default sheet, the span only
    /// with `to`; nil when neither applies.
    static func route(from: String?, to: String?, design: WhatsNewDesign = .sheet) -> String? {
        let span = to.flatMap { $0.isEmpty ? nil : $0 }
        guard span != nil || design != .sheet else { return nil }
        var query = URLComponents()
        query.queryItems = [design == .sheet ? nil : URLQueryItem(name: "design", value: design.rawValue),
                            span.flatMap { _ in from.flatMap { $0.isEmpty ? nil : URLQueryItem(name: "from", value: $0) } },
                            span.map { URLQueryItem(name: "to", value: $0) }].compactMap { $0 }
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
        let provider = changelogNotes(media: services.updater.releaseMedia)
        let native = AppPageNativeProvider(services: services, page: .changelog)
        let routes = [PageRoute(prefix: "cmux.changelog.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        let page = PageWebView(descriptor: .changelog, routes: routes, route: route)
        native.anchor = { [weak page] in page }
        provider.anchor = { [weak page] in page }
        return page
    }

    /// The verified notes (`cmux.changelog.list`, `get`) for the page and the Updated card, and
    /// their PR chips' card (`pr.inspect`, `browser.list`, `browser.openIn`). A DEV build reading
    /// the cmux-next nightly notes is not in their list: no current build, so the page selects the
    /// newest listed one.
    func changelogNotes(media: ReleaseMediaStore? = nil) -> ChangelogPageProvider {
        ChangelogPageProvider(
            source: services.updater.changelogNotes, currentBuild: services.updater.changelogReadsDevelopmentNotes ? "" : services.updater.identity.build,
            media: media,
            // `browser.openIn` with cmux's id, as the agent page's card opens a link: LinkOpener.openWeb,
            // from the pane that shows the page.
            openLink: { [weak services] url, view in
                guard let opener = services?.linkOpener else { return false }
                return opener.openWeb(url, from: view.flatMap(opener.source(containing:)), background: false)
            })
    }
}
