import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-P finds an open workspace by a word of its title and ranks it as Cmd-P does
/// (Lawrence 2026-11-09: "i searched for 'landing' in cmd shift p and didnt find it", the
/// workspace "cmux-next landing"). The command page listed tabs from the plain tab list, so a tab
/// that repeats its workspace's name took a second row under that workspace ("Landing audit…"
/// twice), and every such pair pushed the wanted workspace further down: "land" put it 16th on
/// Cmd-Shift-P and 10th on Cmd-P in the person's 824 workspaces.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct CmdShiftPFindsWorkspacesTests {
    /// The App's three sources in one: the workspaces, every tab (the plain list) and the
    /// navigation entries, which leave out a lone tab (its workspace's row is it).
    @MainActor private final class Store: PaletteWorkspaceSource, PaletteTabSource, PaletteNavigationSource {
        struct Tab { let id: String, title: String, workspace: String, workspaceID: String }
        let workspaceList: [PaletteWorkspace]
        let tabList: [Tab]
        var selected: [String] = []

        init() {
            // Seven workspaces whose title starts with "Land", each with one tab that repeats its name.
            let lands = ["Land queue fix", "Land PR 22436", "Land a490 Chief tools", "Land a603 Kitty remote",
                         "Land or clean every agent", "Land relaunch card removal", "Land Lucas PRs 22059 22058"]
            var workspaces = lands.enumerated().map { PaletteWorkspace(id: "land-\($0.offset)", title: $0.element) }
            var tabs = lands.enumerated().map { Tab(id: "land-tab-\($0.offset)", title: $0.element, workspace: $0.element,
                                                    workspaceID: "land-\($0.offset)") }
            // A workspace named by its first prompt: a chat that repeats the name, and a terminal.
            let audit = "Landing audit: feat-cmux-next The user s…"
            workspaces.append(PaletteWorkspace(id: "audit", title: audit))
            tabs += [Tab(id: "audit-chat", title: audit, workspace: audit, workspaceID: "audit"),
                     Tab(id: "audit-term", title: "Terminal", workspace: audit, workspaceID: "audit")]
            // The one the person looked for: three tabs, none of which names it.
            workspaces.append(PaletteWorkspace(id: "next", title: "cmux-next landing", directory: "~"))
            tabs += [Tab(id: "next-term", title: "Terminal", workspace: "cmux-next landing", workspaceID: "next"),
                     Tab(id: "next-pr", title: "github.com", workspace: "cmux-next landing", workspaceID: "next"),
                     Tab(id: "next-page", title: "cmux NEXT — Chief and your coding agents", workspace: "cmux-next landing",
                         workspaceID: "next")]
            // Unrelated workspaces, so the match competes with a full sidebar.
            for index in 0..<40 {
                workspaces.append(PaletteWorkspace(id: "other-\(index)", title: "Project \(index)"))
                tabs.append(Tab(id: "other-tab-\(index)", title: "zsh", workspace: "Project \(index)", workspaceID: "other-\(index)"))
            }
            workspaceList = workspaces
            tabList = tabs
        }

        var workspaces: [PaletteWorkspace] { workspaceList }
        var tabs: [PaletteTab] { tabList.map { PaletteTab(id: $0.id, title: $0.title, workspaceTitle: $0.workspace) } }
        func navigationEntries() -> [PaletteNavigationEntry] {
            let counts = Dictionary(grouping: tabList, by: \.workspaceID).mapValues(\.count)
            return tabList.filter { counts[$0.workspaceID] != 1 }.map {
                PaletteNavigationEntry(id: $0.id, kind: .tab(.terminal), title: $0.title, workspaceTitle: $0.workspace,
                                       workspaceID: $0.workspaceID)
            }
        }

        func selectWorkspace(id: String) { selected.append(id) }
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

    /// The row ids `action` (Cmd-Shift-P or Cmd-P) shows for `query`, best first.
    private static func rows(_ action: ActionID, _ query: String, store: Store) async -> [String] {
        let (palette, registry) = palette(store)
        defer { palette.closeForTest() }
        _ = registry.perform(action, invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settleDeferredLoads()
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        return palette.model.rows.map(\.item.id)
    }

    /// No tab row repeats its workspace's row: the chat titled like "Landing audit…" is that workspace.
    @Test(arguments: ["landing", "land"])
    func noTabRowRepeatsItsWorkspace(query: String) async {
        let store = Store()
        let ids = await Self.rows("commandPalette", query, store: store)
        let repeats = store.tabList.filter { $0.title == $0.workspace }.map { "tab:\($0.id)" }
        #expect(Set(ids).isDisjoint(with: repeats), "\(query): \(ids.prefix(20))")
    }

    /// A word of the title finds the workspace, at the place Cmd-P puts it, among the first rows the panel shows.
    @Test(arguments: ["landing", "land", "landi", "next landing"])
    func findsTheWorkspaceWhereCmdPDoes(query: String) async throws {
        let store = Store()
        let commands = await Self.rows("commandPalette", query, store: store)
        let goTo = await Self.rows("goToWorkspace", query, store: store)
        let onCommands = try #require(commands.firstIndex(of: "workspace:next"), "\(query): \(commands.prefix(20))")
        let onGoTo = try #require(goTo.firstIndex(of: "workspace:next"), "\(query): \(goTo.prefix(20))")
        #expect(onCommands <= onGoTo, "\(query): Cmd-Shift-P \(commands.prefix(20)), Cmd-P \(goTo.prefix(20))")
        #expect(onCommands < 10, "\(query): \(commands.prefix(20))")
    }

    /// Running the row switches to the workspace.
    @Test func runningTheRowSwitchesToIt() async throws {
        let store = Store()
        let (palette, registry) = Self.palette(store)
        defer { palette.closeForTest() }
        _ = registry.perform("commandPalette", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settleDeferredLoads()
        palette.model.send(.setQuery("landing"))
        await palette.model.settle()
        let row = try #require(palette.model.rows.first { $0.item.id == "workspace:next" })
        palette.model.run(row.item.primary, of: row.item)
        #expect(store.selected == ["next"])
    }
}
