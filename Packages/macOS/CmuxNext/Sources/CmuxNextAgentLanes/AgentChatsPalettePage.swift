import CmuxAgentBrands
public import CmuxNextAgentPane
public import CmuxNextPalette
import Foundation

/// The command palette's chats page (`agentPane.searchChats`, decision K1): the local acpmux
/// daemon's chats, newest first, each opening its chat as a session link does. acpmux searches its
/// own index (P-RUST): the page is a window over it (`palette.chats`) whose spec carries the query,
/// so each query gets acpmux's newest matches and the app holds no copy of the index. It replaces
/// the agent pane's own Search chats sheet, so every search goes through the one command palette.
///
/// The composition root builds it with the feed's windows, the palette's choice history and the
/// app's Open Chat path; the page holds no app state of its own.
@MainActor
public struct AgentChatsPalettePage {
    /// The page's title, as the palette's search scopes name it.
    public static var title: String { AgentChatsPaletteStrings.title }

    static let window = "palette.chats"
    /// The rows one query shows: one page of acpmux's answer.
    static let pageLimit = AgentPaneChatsQuery.maximumLimit

    private let windows: AcpmuxChatWindows?
    private let history: @MainActor (String) async -> String?
    private let open: @MainActor (String) -> Void

    /// - Parameters:
    ///   - windows: The chat feed's windows over acpmux's index; nil without a local acpmux.
    ///   - history: The person's past choices of chats for a query (`FrecencyStore.rankerHistory`
    ///     over the rows' `chat:<key>` use), so acpmux ranks them as the palette does; nil: none. It is
    ///     encoded off the main thread (`FrecencyStore.encodedRankerHistory`), never in a key's turn.
    ///   - open: Opens a chat by key (the app's Open Chat path).
    public init(windows: AcpmuxChatWindows?, history: @escaping @MainActor (String) async -> String?,
                open: @escaping @MainActor (String) -> Void) {
        self.windows = windows
        self.history = history
        self.open = open
    }

    public func page() -> PalettePageSpec {
        PalettePageSpec(id: "agentChats", title: AgentChatsPaletteStrings.title, placeholder: AgentChatsPaletteStrings.placeholder,
                        symbol: "bubble.left.and.bubble.right", providers: [],
                        onCancel: { [windows] in windows?.close(Self.window) },
                        queryResults: { [windows, history, open] query in
                            Self.answers(query, windows: windows, history: history, open: open)
                        },
                        filtersByQuery: false)
    }

    /// The window's rows for `query`: acpmux's first answer to its spec, then the stream ends (the
    /// palette's spinner runs until it ends, and an empty answer shows the empty state). An edit
    /// opens the next query's spec; the window stays open until the page closes.
    /// - Parameters:
    ///   - history: The person's choice history of chats (`FrecencyStore.rankerHistory`), so acpmux
    ///     ranks a chat chosen before as the palette did; nil: none.
    ///   - open: Opens a chat by key (the app's Open Chat path).
    static func answers(_ query: String, windows: AcpmuxChatWindows?, history: @escaping @MainActor (String) async -> String?,
                        open: @escaping @MainActor (String) -> Void) -> AsyncStream<[PaletteItem]> {
        // The choice history is encoded off the main thread first; a query the palette moved past by
        // then (its stream ended) opens no window, so an older spec never replaces a newer one.
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
        let task = Task { @MainActor in
            let encoded = text.isEmpty || windows == nil ? nil : await history(query)
            guard !Task.isCancelled else { return continuation.finish() }
            for await rows in answers(query, windows: windows, history: encoded, open: open) { continuation.yield(rows) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    static func answers(_ query: String, windows: AcpmuxChatWindows?, history: String? = nil,
                        open: @escaping @MainActor (String) -> Void) -> AsyncStream<[PaletteItem]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
        guard let windows else {
            continuation.yield([])
            continuation.finish()
            return stream
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = AcpmuxChatWindows.Spec(window: window, limit: pageLimit, topLevel: true, query: text.isEmpty ? nil : text,
                                          untitled: AgentChatsPaletteStrings.untitled, history: text.isEmpty ? nil : history,
                                          count: true)
        // The follower lives as long as this query's stream: ending it releases the token.
        let token = FollowToken()
        let answer = { (rows: [AcpmuxChat]) in
            var shown = items(rows, windows: windows, open: open)
            // More chats than one page holds: say so, and how to reach the rest (R-L5: a limit
            // that leaves chats out shows it).
            if let total = windows.window(window).total, total > rows.count {
                shown.append(text.isEmpty ? moreChatsNotice(more: total - rows.count) : moreNotice(shown: rows.count, total: total))
            }
            continuation.yield(shown)
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

    /// The last row when more chats match than the page shows: not a command.
    static func moreNotice(shown: Int, total: Int) -> PaletteItem {
        let text = AgentChatsPaletteStrings.moreMatch(shown: shown, total: total)
        return PaletteItem(id: "agentChats.more", title: text, symbol: "info.circle", isEnabled: false,
                           primary: PaletteCommand(id: "none", title: text, effect: .performKeepingOpen {}))
    }

    /// The last row of the empty query when more chats exist than the page shows: not a command.
    static func moreChatsNotice(more: Int) -> PaletteItem {
        let text = AgentChatsPaletteStrings.moreChats(more)
        return PaletteItem(id: "agentChats.more", title: text, symbol: "info.circle", isEnabled: false,
                           primary: PaletteCommand(id: "none", title: text, effect: .performKeepingOpen {}))
    }

    /// Owns one query's follower (released with its stream).
    final class FollowToken: Sendable {}

    static func items(_ chats: [AcpmuxChat], windows: AcpmuxChatWindows, open: @escaping @MainActor (String) -> Void) -> [PaletteItem] {
        let formatter = RelativeDateTimeFormatter()
        return chats.map { chat in
            PaletteItem(
                id: "chat:\(chat.id)", title: chat.title ?? AgentChatsPaletteStrings.untitled,
                subtitle: chat.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath },
                accessory: chat.updatedAt.timeIntervalSince1970 > 0 ? formatter.localizedString(for: chat.updatedAt, relativeTo: Date()) : nil,
                symbol: "bubble.left", brand: chat.brand ?? AgentBrandCatalog.brand(for: chat.harness)?.rawValue,
                keywords: [chat.harness] + (chat.cwd.map { [$0] } ?? []),
                primary: PaletteCommand(id: "open", title: AgentChatsPaletteStrings.open, symbol: "return",
                                        effect: .perform {
                                            // The page closes with this command: its window too.
                                            windows.close(window)
                                            open(chat.id)
                                        }))
        }
    }
}

/// Text of the chats page. Keys live in Resources/Localizable.xcstrings.
struct AgentChatsPaletteStrings {
    static var title: String { String(localized: "handlers.agentChats.title", defaultValue: "Agent Chats", bundle: .module) }
    static var placeholder: String { String(localized: "handlers.agentChats.placeholder", defaultValue: "Search chats", bundle: .module) }
    static var open: String { String(localized: "handlers.agentChats.open", defaultValue: "Open Chat", bundle: .module) }
    static var untitled: String { String(localized: "handlers.agentChats.untitled", defaultValue: "New chat", bundle: .module) }
    /// The bundle of this module's catalog, so a test can read one language's table (`fr.lproj`).
    static var bundle: Bundle { .module }

    /// The row under the empty query's page when `more` chats are not shown. `bundle` and `locale`
    /// default to this module's catalog in the user's language; a test passes one language's table.
    static func moreChats(_ more: Int, bundle: Bundle = .module, locale: Locale = .current) -> String {
        String(localized: "handlers.agentChats.moreChats", defaultValue: "\(more) more chats. Type to search.",
               bundle: bundle, locale: locale)
    }

    /// The row under a page that shows only the best `shown` of `total` matching chats.
    static func moreMatch(shown: Int, total: Int) -> String {
        String(format: String(localized: "handlers.agentChats.moreMatch", defaultValue: "The best %1$lld of %2$lld matching chats. Type more to narrow.",
                              bundle: .module), Int64(shown), Int64(total))
    }
}
