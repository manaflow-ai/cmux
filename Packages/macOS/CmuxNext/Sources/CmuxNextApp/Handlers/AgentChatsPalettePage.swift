import CmuxAgentBrands
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextOnboarding
import CmuxNextPalette
import Foundation

/// The command palette's chats page (`agentPane.searchChats`, decision K1): the local acpmux
/// daemon's chats from the sidebar's Recents feed, newest first, each opening its chat as a
/// session link does; then every other Claude Code and Codex chat on this Mac from the daemon's
/// device index (`_acpmux/chats`), which open as the onboarding chats step resumes them. It
/// replaces the agent pane's own Search chats sheet, so every search goes through the one command
/// palette.
@MainActor
struct AgentChatsPalettePage {
    /// The most device chats the page asks the index for.
    static let deviceLimit = 200

    let services: AppServices

    func page() -> PalettePageSpec {
        let recents = services.agentRecents?.chats ?? []
        let formatter = RelativeDateTimeFormatter()
        let items = recents.map { chat in
            PaletteItem(
                id: "chat:\(chat.id)", title: chat.title ?? AgentChatsPaletteStrings.untitled,
                subtitle: chat.cwd.isEmpty ? nil : (chat.cwd as NSString).abbreviatingWithTildeInPath,
                accessory: chat.updatedAt > 0 ? formatter.localizedString(for: Date(timeIntervalSince1970: chat.updatedAt / 1000), relativeTo: Date()) : nil,
                symbol: "bubble.left", brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue,
                keywords: [chat.harness, chat.cwd],
                primary: PaletteCommand(id: "open", title: AgentChatsPaletteStrings.open, symbol: "return",
                                        effect: .perform { [services] in open(chat.id, services: services) }))
        }
        var providers: [any PaletteProvider] = [StaticPaletteProvider(id: "agentChats", items: items)]
        if let socket = QuitAgents.environment(services)?.socketPath {
            let shown = Set(recents.compactMap(\.agentSessionID))
            providers.append(AsyncPaletteProvider(id: "deviceChats") { [services] in
                let chats = await AcpmuxDeviceChats.newest(socketPath: socket, limit: Self.deviceLimit) ?? []
                return Self.resumable(chats, shown: shown).map { deviceItem($0, services: services, formatter: formatter) }
            })
        }
        return PalettePageSpec(id: "agentChats", title: AgentChatsPaletteStrings.title, placeholder: AgentChatsPaletteStrings.placeholder,
                               symbol: "bubble.left.and.bubble.right", providers: providers)
    }

    /// The device chats this page opens: Claude Code and Codex chats acpmux can adopt, with a
    /// recorded folder, that no Recents row already shows, as the onboarding step's chats.
    static func resumable(_ chats: [AcpmuxDeviceChat], shown: Set<String>) -> [AgentChat] {
        chats.compactMap { chat in
            guard chat.resume == "adopt", !shown.contains(chat.sessionID), let cwd = chat.cwd,
                  let app = AgentApp(indexHarness: chat.harness) else { return nil }
            return AgentChat(sessionID: chat.sessionID, app: app, folder: URL(fileURLWithPath: cwd, isDirectory: true),
                             title: chat.title ?? "", prompts: chat.messageCount ?? 0,
                             lastActive: Date(timeIntervalSince1970: chat.updatedMs / 1000))
        }
    }

    private func deviceItem(_ chat: AgentChat, services: AppServices, formatter: RelativeDateTimeFormatter) -> PaletteItem {
        let folder = (chat.folder.path as NSString).abbreviatingWithTildeInPath
        return PaletteItem(
            id: "device:\(chat.id)", title: chat.title.isEmpty ? AgentChatsPaletteStrings.untitled : chat.title,
            subtitle: folder, accessory: formatter.localizedString(for: chat.lastActive, relativeTo: Date()),
            symbol: "bubble.left", brand: AgentBrandCatalog.brand(for: chat.adoptHarness ?? "")?.rawValue,
            keywords: [chat.app.displayName, chat.folder.path],
            primary: PaletteCommand(id: "open", title: AgentChatsPaletteStrings.open, symbol: "return",
                                    effect: .perform { [services] in resume(chat, services: services) }))
    }

    private func open(_ id: String, services: AppServices) {
        try? DeepLinkNavigator(services: services).open(DeepLink(.session(id, turn: nil)), background: false)
    }

    /// A tab that already resumes the chat comes forward; otherwise the chat opens as the
    /// onboarding chats step opens it.
    private func resume(_ chat: AgentChat, services: AppServices) {
        if let harness = chat.adoptHarness,
           let tab = services.agentTabs.tab(resuming: AgentPaneAdopt(harness: harness, agentSessionId: chat.sessionID)),
           services.revealTab(tab) { return }
        services.onboarding.chatResume.resumeChats([chat])
    }
}

extension AgentApp {
    /// The app of a device index harness id (`claude-code`, `codex`); nil for harnesses acpmux
    /// does not adopt.
    init?(indexHarness: String) {
        switch indexHarness {
        case "claude-code": self = .claudeCode
        case "codex": self = .codex
        default: return nil
        }
    }
}

/// Text of the chats page. Keys live in Resources/MiscHandlers.xcstrings (en, ja).
struct AgentChatsPaletteStrings {
    static var title: String { String(localized: "handlers.agentChats.title", defaultValue: "Agent Chats", table: "MiscHandlers", bundle: .module) }
    static var placeholder: String { String(localized: "handlers.agentChats.placeholder", defaultValue: "Search chats", table: "MiscHandlers", bundle: .module) }
    static var open: String { String(localized: "handlers.agentChats.open", defaultValue: "Open Chat", table: "MiscHandlers", bundle: .module) }
    static var untitled: String { String(localized: "handlers.agentChats.untitled", defaultValue: "New chat", table: "MiscHandlers", bundle: .module) }
}
