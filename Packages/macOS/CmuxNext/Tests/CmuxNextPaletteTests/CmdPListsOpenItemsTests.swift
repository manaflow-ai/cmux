import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-P lists only what is open now: the workspaces and, once typed, their groups, panes and
/// tabs. Browser history, agent chat history, closed tabs and past commands are Search's
/// (Cmd-Shift-A, `CmdShiftASearchesEverythingTests`). Cmd-Shift-P stays the command palette.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct CmdPListsOpenItemsTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "w1", title: "Zebra backend"), PaletteWorkspace(id: "w2", title: "Docs")]
        var selected: [String] = []
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    @MainActor private final class Navigation: PaletteNavigationSource {
        func navigationEntries() -> [PaletteNavigationEntry] {
            [PaletteNavigationEntry(id: "t1", kind: .tab(.terminal), title: "zebra-server", workspaceTitle: "Zebra backend")]
        }
        func open(_ entry: PaletteNavigationEntry) {}
    }

    private static func palette(workspaces: Workspaces = Workspaces()) -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        var sources = PaletteSources(workspaces: workspaces, navigation: Navigation())
        // What Search adds on top: history and agent chats. Cmd-P must not list these.
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

    /// Cmd-P (`goToWorkspace` with no workspace) opens the Workspaces scope, not Search.
    @Test func cmdPOpensTheWorkspacesScope() async {
        let (palette, registry) = Self.palette()
        defer { palette.closeForTest() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        #expect(palette.isVisible)
        #expect(palette.model.nav.levels.last?.scope == PaletteScopeID.workspaces,
                "scope: \(String(describing: palette.model.nav.levels.last?.scope))")
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.isSuperset(of: ["workspace:w1", "workspace:w2"]), "rows: \(ids)")
    }

    /// Typed, Cmd-P finds the open workspaces and tabs, and no history or chat history rows.
    @Test func typedQueriesListOnlyOpenItems() async {
        let workspaces = Workspaces()
        let (palette, registry) = Self.palette(workspaces: workspaces)
        defer { palette.closeForTest() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: [:], origin: .user))
        palette.model.send(.setQuery("zebra"))
        await palette.model.settle()
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.contains("workspace:w1") && ids.contains("tab:t1"), "rows: \(ids)")
        #expect(!ids.contains("history:zebra") && !ids.contains("chat:zebra"), "rows: \(ids)")
        if let row = palette.model.rows.first(where: { $0.item.id == "workspace:w1" }) {
            palette.model.run(row.item.primary, of: row.item)
        }
        #expect(workspaces.selected == ["w1"])
    }

    /// With a workspace argument (a row's ref, the CLI) Go to Workspace still switches to it.
    @Test func goToWorkspaceWithAWorkspaceStillSwitches() async {
        let workspaces = Workspaces()
        let (palette, registry) = Self.palette(workspaces: workspaces)
        defer { palette.closeForTest() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: ["workspace": .string("w2")], origin: .user))
        #expect(workspaces.selected == ["w2"])
        #expect(!palette.isVisible)
    }

    /// The scope rows show the keys that open them: Cmd-P on Workspaces, Cmd-Shift-A on Search.
    @Test func scopeRowsNameTheirKeys() {
        let (palette, registry) = Self.palette()
        defer { palette.closeForTest() }
        let scopes = palette.scopeDescriptors()
        #expect(scopes.first { $0.id == PaletteScopeID.workspaces }?.openAction == "goToWorkspace")
        #expect(scopes.first { $0.id == PaletteScopeID.search }?.openAction == "search.chats")
        #expect(registry.descriptor(for: "commandPalette")?.defaultShortcut == Shortcut("p", modifiers: [.command, .shift]))
        #expect(registry.descriptor(for: "goToWorkspace")?.defaultShortcut == Shortcut("p", modifiers: [.command]))
    }
}
