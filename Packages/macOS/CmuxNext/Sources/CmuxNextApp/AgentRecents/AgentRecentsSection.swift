import AppKit
import CmuxAgentBrands
import CmuxNextAgentPane
import CmuxNextSidebar

/// One window's All chats section, backed by the shared device-wide chat feed.
@MainActor
final class AgentRecentsSection {
    private let feed: ChatsFeed
    private let view = SidebarChatsView()
    var onContentChange: (() -> Void)?
    /// The header's right-click menu (Hide Section).
    var headerMenu: (() -> NSMenu?)? {
        get { view.headerMenu }
        set { view.headerMenu = newValue }
    }

    init(feed: ChatsFeed, open: @escaping (String) -> Void) {
        self.feed = feed
        view.onOpen = open
        refresh()
        feed.observe(self) { [weak self] in self?.refresh() }
    }

    var contentView: NSView? { view }
    var height: CGFloat { view.preferredHeight }

    private func refresh() {
        let rows = feed.chats.map { chat in
            SidebarChatsView.Row(id: chat.id, title: chat.title ?? SidebarChatsView.newChatTitle,
                                 harness: chat.harness, brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue,
                                 folder: chat.cwd, account: chat.accounts.first)
        }
        view.update(rows, enabled: feed.isEnabled, ready: feed.isReady)
        onContentChange?()
    }
}
