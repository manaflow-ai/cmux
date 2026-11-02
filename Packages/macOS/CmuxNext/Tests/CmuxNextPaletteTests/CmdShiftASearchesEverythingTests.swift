import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-A opens Search: open workspaces and tabs plus browser history, agent chats and the
/// rest of history, in one list. Cmd-P lists only what is open (`CmdPListsOpenItemsTests`).
/// Search Tabs keeps its palette row (Cmd-Shift-P), without a default key.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct CmdShiftASearchesEverythingTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "w1", title: "Zebra backend")]
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static func palette() -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        var sources = PaletteSources(workspaces: Workspaces())
        let chat = PaletteItem(id: "chat:zebra", title: "Zebra migration plan", subtitle: "Claude Code",
                               primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}))
        let visit = PaletteItem(id: "history:zebra", title: "Zebra wiki", subtitle: "zebra.wiki",
                                primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}))
        sources.searchContributions = [
            PaletteSearchContribution(id: "agentChats", title: "Agent Chats", order: 30, searchesChats: true) {
                PalettePageSpec(id: "chats.search", title: "Agent Chats", placeholder: "",
                                providers: [StaticPaletteProvider(id: "chats.search", items: [chat])])
            },
            PaletteSearchContribution(id: "history", title: "History", order: 40) {
                PalettePageSpec(id: "history.search", title: "History", placeholder: "",
                                providers: [StaticPaletteProvider(id: "history.search", items: [visit])])
            },
        ]
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return (palette, registry)
    }

    /// Cmd-Shift-A runs `search.chats`; Search Tabs keeps its palette row with no default key.
    @Test func cmdShiftAIsSearch() {
        let (palette, registry) = Self.palette()
        defer { palette.closeForTest() }
        #expect(registry.descriptor(for: "search.chats")?.defaultShortcut == Shortcut("a", modifiers: [.command, .shift]))
        let tabs = registry.descriptor(for: "tab.search")
        #expect(tabs != nil)
        #expect(tabs?.defaultShortcut == nil)
        #expect(tabs?.surfaces.contains(.palette) == true)
    }

    /// It opens Search with no chip: open items, history and agent chats all match.
    @Test func itSearchesEverything() async {
        let (palette, registry) = Self.palette()
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        #expect(palette.isVisible)
        #expect(palette.model.nav.scopePath == [.root, PaletteScopeID.search], "path: \(palette.model.nav.scopePath)")
        #expect(palette.model.pageTitle == PaletteStrings.searchEverythingTitle)
        palette.model.send(.setQuery("zebra"))
        await palette.model.settle()
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.isSuperset(of: ["chat:zebra", "workspace:w1", "history:zebra"]), "rows: \(ids)")
    }

    /// A query argument (the CLI's `--arg query=...`) starts Search with that text.
    @Test func itKeepsTheQueryArgument() async {
        let (palette, registry) = Self.palette()
        defer { palette.closeForTest() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: ["query": .string("zebra")], origin: .user))
        await palette.model.settle()
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.contains("history:zebra"), "rows: \(ids)")
    }
}
