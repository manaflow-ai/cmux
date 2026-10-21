import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Cmd-Shift-A opens the merged Search window with the "Chats & agents" chip set
/// (plans/cmux-next/search-everything-DESIGN.md section 10.1; Lawrence 2026-10-20: Cmd+P and
/// Cmd+Shift+A are one search window). Backspace on the empty field drops the chip and searches
/// everything. Search Tabs keeps its palette row (Cmd-Shift-P), without a default key.
@MainActor
@Suite(.paletteRanker)
struct CmdShiftAOpensChatsSearchTests {
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
    @Test func cmdShiftAIsSearchChatsAndAgents() {
        let (palette, registry) = Self.palette()
        defer { palette.hide() }
        #expect(registry.descriptor(for: "search.chats")?.defaultShortcut == Shortcut("a", modifiers: [.command, .shift]))
        let tabs = registry.descriptor(for: "tab.search")
        #expect(tabs != nil)
        #expect(tabs?.defaultShortcut == nil)
        #expect(tabs?.surfaces.contains(.palette) == true)
    }

    /// It opens Search with the Chats & agents chip on top: only chat rows match.
    @Test func itOpensSearchWithTheChatsChip() async {
        let (palette, registry) = Self.palette()
        defer { palette.hide() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        #expect(palette.isVisible)
        #expect(palette.model.nav.scopePath == [.root, PaletteScopeID.search, PaletteScopeID.chats],
                "path: \(palette.model.nav.scopePath)")
        palette.model.send(.setQuery("zebra"))
        await palette.model.settle()
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.contains("chat:zebra"), "rows: \(ids)")
        #expect(!ids.contains("workspace:w1") && !ids.contains("history:zebra"), "rows: \(ids)")
    }

    /// Backspace on the empty field drops the chip and searches everything.
    @Test func backspaceDropsTheChipToSearchEverything() async {
        let (palette, registry) = Self.palette()
        defer { palette.hide() }
        _ = registry.perform("search.chats", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.backspaceOnEmpty)
        await palette.model.settle()
        #expect(palette.model.nav.scopePath == [.root, PaletteScopeID.search], "path: \(palette.model.nav.scopePath)")
        palette.model.send(.setQuery("zebra"))
        await palette.model.settle()
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.isSuperset(of: ["chat:zebra", "workspace:w1", "history:zebra"]), "rows: \(ids)")
    }
}
