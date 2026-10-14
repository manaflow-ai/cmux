import AppKit
import CmuxNextHistory
import CmuxNextIcons

extension InternalPageID {
    /// Stashed Tabs as a top page: the sidebar item, Show Stashed Tabs and the New Tab link.
    static let stashed = InternalPageID(rawValue: "stashed")
}

/// The Stashed page as a top page: one view per key over the app's one stash model.
@MainActor
final class StashTopPage: InternalPageProvider {
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .stashed }
    var title: String { String(localized: "stash.page.title", defaultValue: "Stashed Tabs", table: "History", bundle: .module) }
    var symbol: String { "tray.full" }
    var icon: IconName? { .tabgroupSave }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let stash = services.historyPage.stash
        return StashPageHostView(model: stash.model, draft: stash.draft(for: key))
    }

    func tabClosed(_ key: String) { services?.historyPage.stash.dropDraft(key) }
}
