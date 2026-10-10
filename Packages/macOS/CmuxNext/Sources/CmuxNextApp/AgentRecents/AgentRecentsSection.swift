import AppKit
import CmuxAgentBrands
import CmuxNextAgentPane
import CmuxNextSidebar
import Observation

/// One window's All chats section, backed by the shared device-wide chat feed.
@MainActor
final class AgentRecentsSection {
    private let feed: ChatsFeed
    private let view = SidebarChatsView()
    /// Follows the TEMPORARY Debug Settings design picker (cx-xub5 vote).
    private var designObservation: Task<Void, Never>?
    var onContentChange: (() -> Void)?
    /// A row's Open in Terminal (its right-click menu).
    var openInTerminal: ((String) -> Void)? {
        get { view.onOpenInTerminal }
        set { view.onOpenInTerminal = newValue }
    }
    /// The header's right-click menu (Hide Section).
    var headerMenu: (() -> NSMenu?)? {
        get { view.headerMenu }
        set { view.headerMenu = newValue }
    }

    init(feed: ChatsFeed, open: @escaping (String) -> Void) {
        self.feed = feed
        view.onOpen = open
        view.onLayoutChange = { [weak self] in self?.onContentChange?() }
        refresh()
        feed.observe(self) { [weak self] in self?.refresh() }
        // task-owner: the section (cancelled in deinit); event-driven (Observation)
        designObservation = Task { [weak self] in
            for await design in Observations({ SidebarChatsDesign.tunable.value }) { self?.view.design = design }
        }
    }

    isolated deinit { designObservation?.cancel() }

    var contentView: NSView? { view }
    var height: CGFloat { view.preferredHeight }

    /// `AgentBrandCatalog.brand(for:)` per harness: a handful of distinct values. Every row
    /// ran the full lookup (trim, lowercase, three splits) on every feed change, the hot loop
    /// of the nightly 3800566557701 hang. Search and the project filter need every row, so
    /// the rows are not capped; the feed publishes at most once per main-actor turn.
    private var brands: [String: String?] = [:]
    private var lastRows: [SidebarChatsView.Row] = []
    private var lastState: (enabled: Bool, ready: Bool)?

    private func refresh() {
        let rows = feed.chats.map { chat in
            SidebarChatsView.Row(id: chat.id, title: chat.title ?? SidebarChatsView.newChatTitle,
                                 harness: chat.harness, brand: brand(chat.harness),
                                 folder: chat.cwd, account: chat.accounts.first, updatedAt: chat.updatedAt)
        }
        // A change outside the shown rows (or a no-op change) redraws and relayouts nothing.
        guard rows != lastRows || lastState?.enabled != feed.isEnabled || lastState?.ready != feed.isReady else { return }
        lastRows = rows
        lastState = (feed.isEnabled, feed.isReady)
        view.update(rows, enabled: feed.isEnabled, ready: feed.isReady)
        onContentChange?()
    }

    private func brand(_ harness: String) -> String? {
        if let known = brands[harness] { return known }
        if brands.count > 256 { brands.removeAll(keepingCapacity: true) }
        let brand = AgentBrandCatalog.brand(for: harness)?.rawValue
        brands[harness] = brand
        return brand
    }
}
