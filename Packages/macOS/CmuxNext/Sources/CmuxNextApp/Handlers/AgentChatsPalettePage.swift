import CmuxAgentBrands
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextPalette
import Foundation

/// The command palette's chats page (`agentPane.searchChats`, decision K1): the local acpmux
/// daemon's chats from the sidebar's Recents feed, newest first, each opening its chat as a
/// session link does. It replaces the agent pane's own Search chats sheet, so every search goes
/// through the one command palette.
@MainActor
struct AgentChatsPalettePage {
    let services: AppServices

    func page() -> PalettePageSpec {
        let chats = services.agentRecents?.chats ?? []
        let formatter = RelativeDateTimeFormatter()
        let items = chats.map { chat in
            PaletteItem(
                id: "chat:\(chat.id)", title: chat.title ?? AgentChatsPaletteStrings.untitled,
                subtitle: chat.cwd.isEmpty ? nil : (chat.cwd as NSString).abbreviatingWithTildeInPath,
                accessory: chat.updatedAt > 0 ? formatter.localizedString(for: Date(timeIntervalSince1970: chat.updatedAt / 1000), relativeTo: Date()) : nil,
                symbol: "bubble.left", brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue,
                keywords: [chat.harness, chat.cwd],
                primary: PaletteCommand(id: "open", title: AgentChatsPaletteStrings.open, symbol: "return",
                                        effect: .perform { [services] in open(chat.id, services: services) }))
        }
        return PalettePageSpec(id: "agentChats", title: AgentChatsPaletteStrings.title, placeholder: AgentChatsPaletteStrings.placeholder,
                               symbol: "bubble.left.and.bubble.right", providers: [StaticPaletteProvider(id: "agentChats", items: items)])
    }

    private func open(_ id: String, services: AppServices) {
        try? DeepLinkNavigator(services: services).open(DeepLink(.session(id, turn: nil)), background: false)
    }
}

/// Text of the chats page. Keys live in Resources/MiscHandlers.xcstrings (en, ja).
struct AgentChatsPaletteStrings {
    static var title: String { String(localized: "handlers.agentChats.title", defaultValue: "Agent Chats", table: "MiscHandlers", bundle: .module) }
    static var placeholder: String { String(localized: "handlers.agentChats.placeholder", defaultValue: "Search chats", table: "MiscHandlers", bundle: .module) }
    static var open: String { String(localized: "handlers.agentChats.open", defaultValue: "Open Chat", table: "MiscHandlers", bundle: .module) }
    static var untitled: String { String(localized: "handlers.agentChats.untitled", defaultValue: "New chat", table: "MiscHandlers", bundle: .module) }
}
