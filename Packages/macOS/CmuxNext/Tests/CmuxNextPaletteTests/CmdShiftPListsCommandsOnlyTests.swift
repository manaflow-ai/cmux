import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-P lists commands, never the open workspaces or tabs (Lawrence 2026-11-15, msg 34162: "cmd shift p should NOT
/// show workspaces or tabs"). Workspaces and tabs belong to Cmd-P (Go to Workspace) and Search (Cmd-Shift-A). The command
/// page had listed them once something was typed since the first palette (4ad8f5076aa5f43, #15514), and 6e5ad6340bf7458
/// added groups, panes and every open tab through the navigation list.
///
/// The guardrail: whatever is typed, the command page reads neither the workspace list, the tab list nor the navigation
/// list, so no provider added to it later can bring their rows back without this suite going red.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct CmdShiftPListsCommandsOnlyTests {
    @MainActor private final class Store: PaletteWorkspaceSource, PaletteTabSource, PaletteNavigationSource {
        var workspaceReads = 0, tabReads = 0, navigationReads = 0
        let entries: [PaletteNavigationEntry]
        let list: [PaletteWorkspace]
        let tabList: [PaletteTab]

        init() {
            list = [PaletteWorkspace(id: "next", title: "cmux-next landing", directory: "~"),
                    PaletteWorkspace(id: "ws", title: "workspace-946"),
                    PaletteWorkspace(id: "settings", title: "Settings polish")]
            tabList = [PaletteTab(id: "t1", title: "Terminal", workspaceTitle: "cmux-next landing"),
                       PaletteTab(id: "t2", title: "github.com", workspaceTitle: "cmux-next landing"),
                       PaletteTab(id: "t3", title: "zsh", workspaceTitle: "workspace-946")]
            entries = [PaletteNavigationEntry(id: "t1", kind: .tab(.terminal), title: "Terminal", workspaceTitle: "cmux-next landing",
                                              workspaceID: "next"),
                       PaletteNavigationEntry(id: "t2", kind: .tab(.terminal), title: "github.com", workspaceTitle: "cmux-next landing",
                                              workspaceID: "next")]
        }

        var workspaces: [PaletteWorkspace] { workspaceReads += 1; return list }
        var tabs: [PaletteTab] { tabReads += 1; return tabList }
        func navigationEntries() -> [PaletteNavigationEntry] { navigationReads += 1; return entries }
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
        func selectTab(id: String) {}
        func renameTab(id: String, to title: String) {}
        func closeTab(id: String) {}
        func open(_ entry: PaletteNavigationEntry) {}
    }

    private static func palette(_ store: Store) -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: store, tabs: store, navigation: store),
                                        frecencyPersistence: nil)
        palette.bindRegistryActions()
        return (palette, registry)
    }

    /// Words of the open workspaces' and tabs' titles, words of commands, and the empty query.
    nonisolated static let queries = ["", "landing", "land", "cmux-next", "workspace", "workspace-946", "Terminal", "github", "zsh", "tab",
                          "Settings polish", "settings", "close", "new"]

    @Test(arguments: queries)
    func cmdShiftPListsNoWorkspaceOrTab(query: String) async {
        let store = Store()
        let (palette, registry) = Self.palette(store)
        defer { palette.closeForTest() }
        _ = registry.perform("commandPalette", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settleDeferredLoads()
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        #expect(palette.model.currentPageID == "commands", "\(query): page \(palette.model.currentPageID ?? "nil")")
        let open = Set(store.list.map { "workspace:\($0.id)" } + store.tabList.map { "tab:\($0.id)" } + store.entries.map(\.itemID))
        let ids = palette.model.rows.map(\.item.id)
        #expect(Set(ids).isDisjoint(with: open), "\(query): \(ids.filter(open.contains))")
        #expect(!ids.contains { $0.hasPrefix("workspace:") || $0.hasPrefix("tab:") }, "\(query): \(ids.prefix(12))")
        #expect(store.workspaceReads == 0 && store.tabReads == 0 && store.navigationReads == 0,
                "\(query): the command page read workspaces \(store.workspaceReads), tabs \(store.tabReads), navigation \(store.navigationReads)")
    }

    /// Cmd-P is unchanged: it lists the open workspace a word of its title finds.
    @Test func cmdPStillFindsTheWorkspace() async {
        let store = Store()
        let (palette, registry) = Self.palette(store)
        defer { palette.closeForTest() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settleDeferredLoads()
        palette.model.send(.setQuery("landing"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.id == "workspace:next" }, "\(palette.model.rows.map(\.item.id).prefix(10))")
    }
}
