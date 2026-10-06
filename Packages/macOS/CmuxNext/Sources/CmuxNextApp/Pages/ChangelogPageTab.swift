import AppKit
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

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .changelog }
    var title: String { ChangelogPageStrings.title }
    var symbol: String { "sparkles" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services, let view = PageFactory(services: services).changelogPage() else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
    }

    /// Opens (or selects) the changelog tab in the active window.
    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true) -> Bool {
        if services.pages.provider(.changelog) == nil { services.pages.register(ChangelogPageTab(services: services)) }
        return services.pages.show(.changelog, in: services.windows.active, focus: focus) != nil
    }
}

nonisolated enum ChangelogPageStrings {
    static var title: String { String(localized: "changelog.page.title", defaultValue: "What's New", table: "Handlers", bundle: .module) }
}

extension PageFactory {
    /// The changelog page: `cmux.changelog.` to verified notes, `cmux.app.` to the native ops
    /// (Try it runs only the descriptor's allow-listed actions).
    func changelogPage() -> PageWebView? {
        let updater = services.updater
        let provider = ChangelogPageProvider(source: updater.releaseNotes, currentBuild: updater.identity.build)
        let native = AppPageNativeProvider(services: services, page: .changelog)
        let routes = [PageRoute(prefix: "cmux.changelog.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        let page = PageWebView(descriptor: .changelog, routes: routes)
        native.anchor = { [weak page] in page }
        return page
    }
}
