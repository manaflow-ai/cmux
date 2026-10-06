import CmuxAgentBrands
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextPalette
import Foundation

/// Search Chats (`agentChats.search`, the sidebar's Search Chats): a palette
/// page over every acpmux chat, newest first, from the Recents feed. A row
/// opens its chat as a session link does. Unlike Cmd-K in a chat
/// (`agentPane.searchChats`) it needs no focused agent pane. A CLI or MCP
/// run opens it only with `focus: true`, because it takes the keyboard.
enum AgentChatSearchHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("agentChats.search", run: { invocation in
            guard invocation.allowsViewChange else { throw ActionFailure(message: AgentChatSearchStrings.needsFocus) }
            guard let feed = services.agentRecents else { throw ActionFailure(message: AgentChatSearchStrings.unavailable) }
            feed.start()
            let open: @MainActor (String) -> Void = { [weak services] id in
                guard let services else { return }
                try? DeepLinkNavigator(services: services).open(DeepLink(.session(id, turn: nil)), background: false)
            }
            services.palette.show(page: page(feed.allChats, query: invocation["query"]?.stringValue ?? "", open: open),
                                  relativeTo: context.activeWindow?.window)
        })
    }

    /// The page: one row per chat, titled as Recents titles it.
    @MainActor
    static func page(_ chats: [AcpmuxRecentChat], query: String = "", open: @escaping @MainActor (String) -> Void) -> PalettePageSpec {
        let rows = chats.map { chat in
            let title = chat.title ?? AgentChatSearchStrings.newChat
            let folder = chat.cwd.isEmpty ? nil : (chat.cwd as NSString).lastPathComponent
            return PaletteItem(id: "chat:\(chat.id)", title: title, subtitle: folder, symbol: "bubble.left",
                               brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue,
                               keywords: [chat.harness] + (folder.map { [$0] } ?? []),
                               primary: PaletteCommand(id: "open", title: AgentChatSearchStrings.open, symbol: "arrow.right",
                                                       effect: .perform { open(chat.id) }),
                               frecencyKey: "chat:\(chat.id)")
        }
        return PalettePageSpec(id: "agentChats.search", title: AgentChatSearchStrings.title, placeholder: AgentChatSearchStrings.placeholder,
                               symbol: "magnifyingglass", providers: [StaticPaletteProvider(id: "chats", items: rows)],
                               initialQuery: query, keepsSectionOrder: true)
    }
}

/// Strings of Search Chats (table MiscHandlers.xcstrings).
nonisolated enum AgentChatSearchStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "MiscHandlers", bundle: .module)
    }

    static var title: String { t("agentChats.search.title", "Search Chats") }
    static var placeholder: String { t("agentChats.search.placeholder", "Search chats") }
    static var open: String { t("agentChats.search.open", "Open") }
    static var newChat: String { t("agentChats.search.newChat", "New chat") }
    static var needsFocus: String { t("agentChats.search.needsFocus", "Search Chats opens only when focus is requested") }
    static var unavailable: String { t("agentChats.search.unavailable", "Agent chats are not available in this build") }
}
