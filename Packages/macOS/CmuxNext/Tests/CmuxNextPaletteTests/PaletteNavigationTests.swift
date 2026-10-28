import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import Foundation
import Testing

/// Go to Workspace (Cmd-P) searches groups, panes and tabs next to the
/// workspaces: the rows show their kind and parents, ranking puts whole and
/// prefix matches first and the recently used next, and choosing a row goes
/// there through the source.
@MainActor
@Suite(.paletteRanker)
struct PaletteNavigationTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = []
        var selected: [String] = []
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    @MainActor private final class Navigation: PaletteNavigationSource {
        var entries: [PaletteNavigationEntry] = []
        var opened: [String] = []
        /// How many times the palette read the source (each read builds every row's item).
        var reads = 0
        func navigationEntries() -> [PaletteNavigationEntry] {
            reads += 1
            return entries
        }
        func open(_ entry: PaletteNavigationEntry) { opened.append(entry.itemID) }
    }

    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private static func palette(_ workspaces: Workspaces, _ navigation: Navigation) -> PaletteController {
        _ = NSApplication.shared
        return PaletteController(registry: ActionRegistry.standard(),
                                 sources: PaletteSources(workspaces: workspaces, navigation: navigation), frecencyPersistence: nil)
    }

    private static func ids(_ palette: PaletteController) -> [String] { palette.model.rows.map(\.item.id) }

    private static func search(_ palette: PaletteController, _ query: String) async -> [String] {
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        return ids(palette)
    }

    // MARK: Item building

    @Test func rowsShowTheirKindAndParents() throws {
        let entries = [
            PaletteNavigationEntry(id: "g1", kind: .group(workspaceCount: 3), title: "Backend", color: .blue),
            PaletteNavigationEntry(id: "p1", kind: .pane, title: "", workspaceTitle: "api", groupTitle: "Backend"),
            PaletteNavigationEntry(id: "p1", kind: .tab(.browser), title: "Docs", workspaceTitle: "api", groupTitle: "Backend",
                                   url: "https://www.example.com/docs"),
            PaletteNavigationEntry(id: "t2", kind: .tab(.terminal), title: "", workspaceTitle: "api", cwd: "/srv/api", isCurrent: true),
            PaletteNavigationEntry(id: "t3", kind: .tab(.agentChat), title: "Fix the build", workspaceTitle: "api", agent: "claude"),
        ]
        let items = NavigationPaletteProvider.items(entries, source: nil)
        // A pane and a tab with the same id are two rows.
        #expect(items.map(\.id) == ["group:g1", "pane:p1", "tab:p1", "tab:t2", "tab:t3"])

        let group = items[0]
        #expect(group.symbol == "folder")
        #expect(group.ball == PaletteBall(.blue))
        #expect(group.accessory == "Group")
        #expect(group.subtitle == "Workspaces: 3")
        #expect(group.keywords.contains("group"))

        let pane = items[1]
        #expect(pane.title == "Pane")
        #expect(pane.accessory == "Pane")
        #expect(pane.subtitle == "api · Backend")
        #expect(pane.actionRefs.first?.action == "pane.focus")

        let browser = items[2]
        #expect(browser.symbol == "globe")
        #expect(browser.accessory == "Browser")
        #expect(browser.subtitle == "api · Backend · example.com")
        #expect(browser.keywords.contains("https://www.example.com/docs"))
        #expect(browser.actionRefs.first?.action == "tab.focus")

        let terminal = items[3]
        #expect(terminal.title == "Untitled")
        #expect(terminal.accessory == "Current")
        #expect(terminal.keywords.contains("/srv/api"))

        let chat = items[4]
        #expect(chat.accessory == "Agent Chat")
        #expect(chat.brand == "claude")
    }

    @Test func recentlyUsedRowsGetTheLargerRecencyBoost() {
        let entries = [
            PaletteNavigationEntry(id: "old", kind: .tab(.terminal), title: "shell", lastUsed: Self.now.addingTimeInterval(-3_600)),
            PaletteNavigationEntry(id: "never", kind: .tab(.terminal), title: "shell"),
            PaletteNavigationEntry(id: "new", kind: .tab(.terminal), title: "shell", lastUsed: Self.now),
        ]
        let bias = Dictionary(uniqueKeysWithValues: NavigationPaletteProvider.items(entries, source: nil).map { ($0.id, $0.rankBias) })
        #expect(bias["tab:new"]! > bias["tab:old"]!)
        #expect(bias["tab:old"]! > bias["tab:never"]!)
        #expect(bias["tab:never"] == NavigationPaletteProvider.tabBias)
    }

    @Test func workspaceRowsNameTheirGroup() {
        let workspaces = Workspaces()
        workspaces.workspaces = [PaletteWorkspace(id: "w1", title: "api", directory: "/srv/api", groupName: "Backend")]
        let item = WorkspacePaletteProvider(source: workspaces, showsItemsForEmptyQuery: true).makeItems()[0]
        #expect(item.subtitle == "Backend · /srv/api")
        #expect(item.keywords.contains("Backend"))
    }

    /// Machine identity: with workspaces on more than one machine, a row leads with its machine,
    /// and typing the machine's name finds its workspaces.
    @Test func workspaceRowsNameTheirMachine() {
        let workspaces = Workspaces()
        workspaces.workspaces = [PaletteWorkspace(id: "w1", title: "api", directory: "/srv/api", groupName: "Backend", machineName: "gpu-box")]
        let item = WorkspacePaletteProvider(source: workspaces, showsItemsForEmptyQuery: true).makeItems()[0]
        #expect(item.subtitle == "gpu-box · Backend · /srv/api")
        #expect(item.keywords.contains("gpu-box"))
    }

    // MARK: Ranking

    @Test func emptyQueryListsWorkspacesAndTypingFindsEverything() async {
        let workspaces = Workspaces()
        workspaces.workspaces = [PaletteWorkspace(id: "w1", title: "frontend"), PaletteWorkspace(id: "w2", title: "backend")]
        let navigation = Navigation()
        navigation.entries = [
            PaletteNavigationEntry(id: "g1", kind: .group(workspaceCount: 2), title: "Releases"),
            PaletteNavigationEntry(id: "p1", kind: .pane, title: "logs", workspaceTitle: "backend"),
            PaletteNavigationEntry(id: "t1", kind: .tab(.browser), title: "Release notes", workspaceTitle: "frontend"),
        ]
        let palette = Self.palette(workspaces, navigation)
        defer { palette.hide() }
        palette.show(.workspaces)
        await palette.model.settle()
        #expect(Set(Self.ids(palette)) == ["workspace:w1", "workspace:w2"])

        // A whole-title match first; a prefix finds the group and the tab.
        #expect(await Self.search(palette, "releases").first == "group:g1")
        #expect(Set(await Self.search(palette, "release")).isSuperset(of: ["group:g1", "tab:t1"]))
        #expect(await Self.search(palette, "logs").first == "pane:p1")
        // The parent workspace finds its tabs and panes too.
        #expect(await Self.search(palette, "backend").first == "workspace:w2")
        #expect(await Self.search(palette, "backend").contains("pane:p1"))
    }

    @Test func recencyBreaksTiesBetweenEqualMatches() async {
        let workspaces = Workspaces()
        workspaces.workspaces = [PaletteWorkspace(id: "w1", title: "deploy")]
        let navigation = Navigation()
        navigation.entries = [
            PaletteNavigationEntry(id: "old", kind: .tab(.terminal), title: "deploy", lastUsed: Self.now.addingTimeInterval(-60)),
            PaletteNavigationEntry(id: "new", kind: .tab(.terminal), title: "deploy", lastUsed: Self.now),
        ]
        let palette = Self.palette(workspaces, navigation)
        defer { palette.hide() }
        palette.show(.workspaces)
        let ranked = await Self.search(palette, "deploy")
        #expect(Set(ranked).isSuperset(of: ["workspace:w1", "tab:new", "tab:old"]))
        #expect(ranked.firstIndex(of: "tab:new")! < ranked.firstIndex(of: "tab:old")!)
    }

    @Test func choosingAGroupRowOpensItThroughTheSource() async {
        let workspaces = Workspaces()
        let navigation = Navigation()
        navigation.entries = [PaletteNavigationEntry(id: "g1", kind: .group(workspaceCount: 1), title: "Infra")]
        let palette = Self.palette(workspaces, navigation)
        defer { palette.hide() }
        palette.show(.workspaces)
        #expect(await Self.search(palette, "infra").first == "group:g1")
        _ = palette.model.handle(.submit)
        #expect(navigation.opened == ["group:g1"])
    }

    // MARK: Agent sessions

    @Test func aSessionRowCopiesItsSessionIDAndIsFoundByIt() async throws {
        let workspaces = Workspaces()
        let navigation = Navigation()
        navigation.entries = [
            PaletteNavigationEntry(id: "chat", kind: .tab(.agentChat), title: "Fix CI", workspaceTitle: "api", sessionID: "acp:s_3f9a"),
            PaletteNavigationEntry(id: "term", kind: .tab(.terminal), title: "claude", agent: "claude",
                                   sessionID: "0d8f6c1e-2b7a-4c55-9a51-7e2f4b1c9d30"),
            PaletteNavigationEntry(id: "plain", kind: .tab(.terminal), title: "zsh"),
        ]
        let items = NavigationPaletteProvider.items(navigation.entries, source: nil)
        #expect(items[0].secondary.map(\.id) == ["copySessionID"])
        #expect(items[0].secondary.first?.title == "Copy Session ID")
        #expect(items[2].secondary.isEmpty)

        let palette = Self.palette(workspaces, navigation)
        defer { palette.hide() }
        palette.show(.workspaces)
        // The acpmux handle, its bare id, and a Claude session UUID each find their row.
        #expect(await Self.search(palette, "acp:s_3f9a").first == "tab:chat")
        #expect(await Self.search(palette, "s_3f9a").first == "tab:chat")
        #expect(await Self.search(palette, "0d8f6c1e-2b7a").first == "tab:term")

        // Cmd-K opens the highlighted row's Actions menu, which lists Copy Session ID.
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k",
                                                  isARepeat: false, keyCode: 40))
        #expect(PaletteKeyMap.isActionsKey(event))
        let command = PaletteKeyMap.command(for: event, actionsMenuOpen: false, queryIsEmpty: false, registry: palette.registry)
        #expect(command == .toggleActions)
        #expect(palette.model.handle(.toggleActions))
        #expect(palette.model.actionsMenu?.itemID == "tab:term")
        #expect(palette.model.actionsMenu?.commands.map(\.id).contains("copySessionID") == true)
        // Cmd-K again hides it.
        #expect(PaletteKeyMap.command(for: event, actionsMenuOpen: true, queryIsEmpty: false, registry: palette.registry) == .toggleActions)
    }

    /// Cmd-P (`goToWorkspace`, the Workspaces scope) and Cmd-Shift-A (`search.chats`, the
    /// Search scope) both open a page where Cmd-K on an agent row offers Copy Session ID.
    @Test(arguments: ["goToWorkspace", "search.chats"])
    func cmdKCopiesTheSessionIDFromEachPaletteEntryPoint(_ action: String) async throws {
        let workspaces = Workspaces()
        let navigation = Navigation()
        navigation.entries = [
            PaletteNavigationEntry(id: "chat", kind: .tab(.agentChat), title: "Fix CI", workspaceTitle: "api", sessionID: "acp:s_3f9a"),
        ]
        let palette = Self.palette(workspaces, navigation)
        palette.bindRegistryActions()
        defer { palette.hide() }
        for task in palette.registry.capturingWork({ #expect(palette.registry.perform(ActionID(rawValue: action))) }) { _ = await task.value }
        #expect(palette.isVisible)
        #expect(await Self.search(palette, "s_3f9a").first == "tab:chat")
        #expect(palette.model.handle(.toggleActions))
        #expect(palette.model.actionsMenu?.itemID == "tab:chat")
        #expect(palette.model.actionsMenu?.commands.map(\.id).contains("copySessionID") == true)
    }

    /// 5,000 tabs rank without the palette rebuilding them per keystroke: no new read of the
    /// source and no new search index after the first key. Counted, not timed: a 5 s wall-clock
    /// limit failed on a loaded fleet host (9.27 s on aws-m4pro-4, 2026-10-21) with nothing wrong.
    @Test func manyEntriesRankWithoutARebuildPerKeystroke() async {
        let workspaces = Workspaces()
        workspaces.workspaces = (0..<200).map { PaletteWorkspace(id: "w\($0)", title: "workspace \($0)") }
        let navigation = Navigation()
        navigation.entries = (0..<5_000).map { index in
            PaletteNavigationEntry(id: "t\(index)", kind: .tab(.terminal), title: "tab \(index)", workspaceTitle: "workspace \(index % 200)",
                                   cwd: "/Users/me/src/project-\(index)")
        }
        let palette = Self.palette(workspaces, navigation)
        defer { palette.hide() }
        palette.show(.workspaces)
        let query = "tab 4321"
        _ = await Self.search(palette, String(query.prefix(1)))
        let readsAfterFirstKey = navigation.reads
        let indexAfterFirstKey = palette.model.current?.version
        #expect(readsAfterFirstKey >= 1, "the palette never read its tabs")
        var ranked: [String] = []
        for length in 2...query.count { ranked = await Self.search(palette, String(query.prefix(length))) }
        #expect(ranked.first == "tab:t4321")
        #expect(navigation.reads == readsAfterFirstKey,
                "typing \(query.count - 1) more keys read the 5,000 tabs \(navigation.reads - readsAfterFirstKey) more times")
        #expect(palette.model.current?.version == indexAfterFirstKey, "typing rebuilt the search index of the 5,000 tabs")
    }
}
