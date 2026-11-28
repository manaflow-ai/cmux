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

    private func refresh() {
        let rows = feed.chats.map { chat in
            SidebarChatsView.Row(id: chat.id, title: chat.title ?? SidebarChatsView.newChatTitle,
                                 harness: chat.harness, brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue,
                                 folder: chat.cwd, account: chat.accounts.first, updatedAt: chat.updatedAt)
        }
        view.update(rows, enabled: feed.isEnabled, ready: feed.isReady)
        onContentChange?()
    }
}
