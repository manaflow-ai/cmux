import AppKit
import CmuxNextHistory
import CmuxNextHistoryPages
import CmuxNextIcons
import CmuxNextPages

extension InternalPageID {
    /// Stashed Tabs as a top page: Show Stashed Tabs (the palette, Window menu, CLI and MCP),
    /// Import from OneTab… and the `cmux://stashed` address open it.
    static let stashed = InternalPageID(rawValue: "stashed")
}

/// The Stashed Tabs page as a top page: one React page (cmux-page://cmux.stash/) per key, each
/// with its own search and OneTab paste box.
@MainActor
final class StashTopPage: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]
    /// Import from OneTab… asked before the page existed: the next page made opens its box.
    private var importOnOpen = false

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .stashed }
    var title: String { StashPageProvider.title }
    var symbol: String { "tray.full" }
    var icon: IconName? { .tabgroupSave }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let route = importOnOpen ? "#/import" : nil
        importOnOpen = false
        guard let services, let page = PageFactory(services: services).stashWebPage(route: route) else { return NSView() }
        pages[key] = page
        return page
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }

    /// Opens the OneTab paste box of the page `show` opens: a page made by `show` opens with it,
    /// one already open is told to.
    func openImport(show: () throws -> String) rethrows {
        importOnOpen = true
        defer { importOnOpen = false }
        let key = try show()
        if importOnOpen, let page = pages[key] { page.send(command: "open", arguments: ["text": .string("import")]) }
    }
}
