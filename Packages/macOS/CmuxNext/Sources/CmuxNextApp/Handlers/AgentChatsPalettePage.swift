import CmuxAgentBrands
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextPalette
import Foundation

/// The command palette's chats page (`agentPane.searchChats`, decision K1): the local acpmux
/// daemon's chats, newest first, each opening its chat as a session link does. acpmux searches its
/// own index (P-RUST): the page is a window over it (`palette.chats`) whose spec carries the query,
/// so each query gets acpmux's newest matches and the app holds no copy of the index. It replaces
/// the agent pane's own Search chats sheet, so every search goes through the one command palette.
@MainActor
struct AgentChatsPalettePage {
    let services: AppServices

    static let window = "palette.chats"
    /// The rows one query shows: one page of acpmux's answer.
    static let pageLimit = AgentPaneChatsQuery.maximumLimit

    func page() -> PalettePageSpec {
        let windows = services.chatsFeed?.windows
        return PalettePageSpec(id: "agentChats", title: AgentChatsPaletteStrings.title, placeholder: AgentChatsPaletteStrings.placeholder,
                               symbol: "bubble.left.and.bubble.right", providers: [],
                               onCancel: { windows?.close(Self.window) },
                               queryResults: { [services] query in Self.answers(query, windows: windows, services: services) },
                               filtersByQuery: false)
    }

    /// The window's rows for `query`: acpmux's first answer to its spec, then the stream ends (the
    /// palette's spinner runs until it ends, and an empty answer shows the empty state). An edit
    /// opens the next query's spec; the window stays open until the page closes.
    static func answers(_ query: String, windows: AcpmuxChatWindows?, services: AppServices) -> AsyncStream<[PaletteItem]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
        guard let windows else {
            continuation.yield([])
            continuation.finish()
            return stream
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = AcpmuxChatWindows.Spec(window: window, limit: pageLimit, topLevel: true, query: text.isEmpty ? nil : text)
        // The follower lives as long as this query's stream: ending it releases the token.
        let token = FollowToken()
        let answer = { (rows: [AcpmuxChat]) in
            continuation.yield(items(rows, windows: windows, services: services))
            continuation.finish()
        }
        windows.window(window).follow(token) { rows in
            if windows.isAnswered(spec) { answer(rows) }
        }
        windows.open(spec)
        if windows.isAnswered(spec) { answer(windows.window(window).rows) }
        continuation.onTermination = { _ in withExtendedLifetime(token) {} }
        return stream
    }

    /// Owns one query's follower (released with its stream).
    final class FollowToken: Sendable {}

    static func items(_ chats: [AcpmuxChat], windows: AcpmuxChatWindows, services: AppServices) -> [PaletteItem] {
        let formatter = RelativeDateTimeFormatter()
        return chats.map { chat in
            PaletteItem(
                id: "chat:\(chat.id)", title: chat.title ?? AgentChatsPaletteStrings.untitled,
                subtitle: chat.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath },
                accessory: chat.updatedAt.timeIntervalSince1970 > 0 ? formatter.localizedString(for: chat.updatedAt, relativeTo: Date()) : nil,
                symbol: "bubble.left", brand: chat.brand ?? AgentBrandCatalog.brand(for: chat.harness)?.rawValue,
                keywords: [chat.harness] + (chat.cwd.map { [$0] } ?? []),
                primary: PaletteCommand(id: "open", title: AgentChatsPaletteStrings.open, symbol: "return",
                                        effect: .perform { [services] in
                                            // The page closes with this command: its window too.
                                            windows.close(window)
                                            services.chatsOpener.open(chat.id)
                                        }))
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
