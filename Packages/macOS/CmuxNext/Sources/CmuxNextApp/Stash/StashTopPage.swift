import AppKit
import CmuxNextHibernation
import CmuxNextHistory
import CmuxNextIcons

extension InternalPageID {
    /// Stashed Tabs as a top page: Show Stashed Tabs (the palette, Window menu, CLI and MCP),
    /// Import from OneTab… and the `cmux://stashed` address open it.
    static let stashed = InternalPageID(rawValue: "stashed")
}

/// The Stashed page as a top page: one view per key over the app's one stash model.
@MainActor
final class StashTopPage: InternalPageProvider {
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .stashed }
    var title: String { StashPageModel.title }
    var symbol: String { "tray.full" }
    var icon: IconName? { .tabgroupSave }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let stash = services?.historyPage.stash else { return NSView() }
        return StashPageHostView(model: stash.model, draft: stash.draft(for: key))
    }

    func tabClosed(_ key: String) { services?.historyPage.stash.dropDraft(key) }

    // MARK: Discard

    /// Ten minutes hidden (Chrome's proactive_discarding_policy.cc). The tab's search and OneTab
    /// paste box live in its draft (``StashImportDraft``), which the stash keeps until the tab
    /// closes, so the view made again shows them; the default view state adds the scroll.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }
}
