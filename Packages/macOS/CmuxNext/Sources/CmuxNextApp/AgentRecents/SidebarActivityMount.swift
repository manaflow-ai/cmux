import AppKit
import CmuxAgentBrands
import CmuxNextAgentPane
import CmuxNextSidebar

/// One window's Activity view (`sidebar.activityView`, meeting 2026-10-08
/// AV): while the setting is on, the sidebar's Activity view mirrors the
/// device-wide chat feed, attention and previews included (acpmux joins
/// them). While it is off nothing observes the feed for it. A click opens
/// the chat in a new pane to the right, as All chats does.
@MainActor
final class SidebarActivityMount {
    private var binding: Binding?

    /// Starts or stops feeding `view` after a settings change.
    func show(_ on: Bool, in view: SidebarActivityView, services: AppServices) {
        guard on != (binding != nil) else { return }
        binding = on ? services.chatsFeed.map { feed in
            view.onOpen = { [weak services] id in services?.chatsOpener.open(id, placement: .splitRight) }
            return Binding(feed: feed, view: view)
        } : nil
    }

    /// A feed chat as the Activity view shows it.
    static func chat(_ chat: AcpmuxChat) -> SidebarActivityChat {
        SidebarActivityChat(id: chat.id, title: chat.title ?? SidebarChatsView.newChatTitle, harness: chat.harness,
                            brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue, updatedAt: chat.updatedAt,
                            attention: chat.attention.flatMap(attention), preview: chat.preview)
    }

    /// acpmux's attention names (`chats/activity.rs`); an unknown one shows no dot.
    static func attention(_ name: String) -> SidebarActivityAttention? {
        switch name {
        case "needsInput": .needsInput
        case "failed": .failed
        case "unread": .unread
        default: nil
        }
    }

    /// The feed observer; the feed drops it once released.
    private final class Binding {
        private let feed: ChatsFeed
        private weak var view: SidebarActivityView?

        init(feed: ChatsFeed, view: SidebarActivityView) {
            self.feed = feed
            self.view = view
            refresh()
            feed.observe(self) { [weak self] in self?.refresh() }
        }

        private func refresh() {
            view?.update(feed.chats.map(SidebarActivityMount.chat), ready: feed.isReady)
        }
    }
}
