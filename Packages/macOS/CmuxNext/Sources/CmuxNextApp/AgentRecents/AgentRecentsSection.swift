import AppKit
import CmuxAgentBrands
import CmuxNextSidebar

/// One window's Recents section (`SidebarRecentsView.contribution`): the
/// shared feed's chats as rows, each opening its chat as a session link
/// does. With no chats there is no view, so the section draws nothing.
@MainActor
final class AgentRecentsSection {
    private let feed: AgentRecentsFeed
    private let view = SidebarRecentsView()
    var onContentChange: (() -> Void)?

    init(feed: AgentRecentsFeed, open: @escaping (String) -> Void) {
        self.feed = feed
        view.onOpen = open
        refresh()
        feed.observe(self) { [weak self] in self?.refresh() }
    }

    var contentView: NSView? { feed.chats.isEmpty ? nil : view }
    var height: CGFloat { SidebarRecentsView.height(rows: feed.chats.count) }

    private func refresh() {
        view.update(feed.chats.map { chat in
            SidebarRecentsView.Row(id: chat.id, title: chat.title ?? SidebarRecentsView.newChatTitle,
                                   brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue)
        })
        onContentChange?()
    }
}
