import AppKit
import CmuxNextActions
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
@testable import CmuxNextPalette
import Foundation
import Testing

/// Review of #28090 at 63702fa5c22 (F1): the chats page finds its rows by asking acpmux for each
/// query (`PalettePageSpec.queryResults`) and has no providers. Search (Cmd-Shift-A) and the Chats &
/// agents scope read a contributed page through its providers only, so they listed no chats at all.
/// These open both with the real page, contributed as the App contributes it (PaletteSourcesBridge),
/// and answer for acpmux.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentChatsJoinSearchTests {
    /// The palette with the chats page as Search's agent chats contribution, over `windows`.
    static func palette(windows: AcpmuxChatWindows) -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        var sources = PaletteSources()
        sources.searchContributions = [
            PaletteSearchContribution(id: "agentChats", title: AgentChatsPalettePage.title, order: 30, searchesChats: true) {
                AgentChatsPalettePage(windows: windows, history: { _ in nil }, open: { _ in }).page()
            },
        ]
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return (palette, registry)
    }

    /// acpmux's answer to the window's last spec: one chat.
    static func answer(_ windows: AcpmuxChatWindows, to params: [String: any Sendable]) throws {
        let generation = try #require(params["gen"] as? UInt64)
        let row: [String: Any] = ["key": "codex:1", "sessionId": "1", "harness": "codex", "title": "Zebra migration plan",
                                  "updatedMs": 1_000]
        let message: [String: Any] = ["window": AgentChatsPalettePage.window, "gen": NSNumber(value: generation), "revision": 1,
                                      "full": true, "keys": ["codex:1"], "rows": [row]]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: message)))
    }

    /// The rows on screen once `id` shows (an answer lands on a later main-actor turn), or as they are.
    static func rows(showing id: String, in palette: PaletteController) async -> [PaletteRow] {
        for _ in 0..<500 where !palette.model.rows.contains(where: { $0.item.id == id }) {
            await Task.yield()
        }
        return palette.model.rows
    }

    /// Search asks acpmux for the typed query and lists its chats under Agent Chats.
    @Test func searchListsTheChatsAcpmuxFindsForTheQuery() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { _, params in sent.append(params) }
        let (palette, registry) = Self.palette(windows: windows)
        defer { palette.hide() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery("zebra"))
        await palette.model.settle()
        // The page is asked in a later turn than the key's, after the choice history is encoded off main.
        for _ in 0..<500 where !sent.contains(where: { $0["query"] as? String == "zebra" }) { await Task.yield() }
        let asked = sent.last { $0["window"] as? String == AgentChatsPalettePage.window }
        #expect(asked?["query"] as? String == "zebra", "Search asks acpmux for the query: \(sent)")
        try Self.answer(windows, to: try #require(asked))
        let rows = await Self.rows(showing: "chat:codex:1", in: palette)
        let chat = rows.first { $0.item.id == "chat:codex:1" }
        #expect(chat != nil, "rows: \(rows.map(\.item.id))")
        #expect(chat?.item.section.title == AgentChatsPalettePage.title, "the chat shows under Agent Chats")
    }

    /// The Chats & agents scope lists acpmux's newest chats before any typing.
    @Test func theChatsScopeListsTheNewestChats() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { _, params in sent.append(params) }
        let (palette, _) = Self.palette(windows: windows)
        defer { palette.hide() }
        _ = palette.show(scope: PaletteScopeID.chats)
        await palette.model.settle()
        for _ in 0..<500 where !sent.contains(where: { $0["window"] as? String == AgentChatsPalettePage.window }) { await Task.yield() }
        let asked = sent.last { $0["window"] as? String == AgentChatsPalettePage.window }
        #expect(asked != nil, "the scope asks acpmux for its newest chats: \(sent)")
        #expect(asked?["query"] == nil, "the empty query asks for the newest, not a match")
        try Self.answer(windows, to: try #require(asked))
        let rows = await Self.rows(showing: "chat:codex:1", in: palette)
        #expect(rows.contains { $0.item.id == "chat:codex:1" }, "rows: \(rows.map(\.item.id))")
    }
}
