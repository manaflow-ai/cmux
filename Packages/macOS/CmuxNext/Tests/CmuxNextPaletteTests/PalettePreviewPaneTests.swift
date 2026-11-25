import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// The preview look (`experiments.palettePreview`): the detail pane lists the highlighted row's facts from what the
/// app already has (a workspace's folder and counts, a session's kind, place and agent, a command's shortcut), read for
/// that row only; Cmd-K opens the row's Actions menu, while with the look off it keeps editing an action's shortcut.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PalettePreviewPaneTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private static func labels(_ facts: [PaletteFact]) -> [String] { facts.map(\.label) }
    private static func value(_ facts: [PaletteFact], _ label: String) -> String? { facts.first { $0.label == label }?.value }

    // MARK: Facts

    @Test func aWorkspaceListsItsFolderCountsBranchAndLastActivity() {
        let workspace = PaletteWorkspace(id: "w1", title: "api", directory: NSHomeDirectory() + "/src/api", groupName: "Backend",
                                         lastUsed: Self.now.addingTimeInterval(-300), tabCount: 3, agentCount: 1, branch: "main")
        let facts = PaletteFacts.workspace(workspace, now: Self.now)
        #expect(Self.labels(facts) == [PaletteStrings.factName, PaletteStrings.factDirectory, PaletteStrings.factTabs,
                                       PaletteStrings.factAgents, PaletteStrings.factBranch, PaletteStrings.factGroup,
                                       PaletteStrings.factLastActive])
        #expect(Self.value(facts, PaletteStrings.factName) == "api")
        #expect(Self.value(facts, PaletteStrings.factDirectory) == "~/src/api")
        #expect(Self.value(facts, PaletteStrings.factTabs) == "3")
        #expect(Self.value(facts, PaletteStrings.factAgents) == "1")
        #expect(Self.value(facts, PaletteStrings.factBranch) == "main")
    }

    @Test func aWorkspaceTheSourceSaysLittleAboutListsOnlyWhatItKnows() {
        let facts = PaletteFacts.workspace(PaletteWorkspace(id: "w1", title: "notes", isSelected: true), now: Self.now)
        #expect(Self.labels(facts) == [PaletteStrings.factName, PaletteStrings.factStatus])
        #expect(Self.value(facts, PaletteStrings.factStatus) == PaletteStrings.current)
    }

    @Test func aWorkspaceRowReadsItsFactsOnlyWhenAsked() throws {
        @MainActor final class Workspaces: PaletteWorkspaceSource {
            var workspaces = [PaletteWorkspace(id: "w1", title: "api", tabCount: 2)]
            func selectWorkspace(id: String) {}
            func renameWorkspace(id: String, to title: String) {}
            func closeWorkspace(id: String) {}
        }
        let provider = WorkspacePaletteProvider(source: Workspaces(), showsItemsForEmptyQuery: true)
        provider.now = { Self.now }
        let item = try #require(provider.makeItems().first)
        let readFacts = try #require(item.facts)
        let facts = readFacts()
        #expect(facts == PaletteFacts.workspace(PaletteWorkspace(id: "w1", title: "api", tabCount: 2), now: Self.now))
    }

    @Test func aSessionListsItsKindPlaceAgentAndState() throws {
        let entry = PaletteNavigationEntry(id: "chat", kind: .tab(.agentChat), title: "Fix CI", workspaceTitle: "api",
                                           cwd: NSHomeDirectory() + "/src/api", agent: "claude", sessionID: "acp:s_3f9a",
                                           isCurrent: true, lastUsed: Self.now.addingTimeInterval(-60))
        let facts = PaletteFacts.navigation(entry, now: Self.now)
        #expect(Self.labels(facts) == [PaletteStrings.factTitle, PaletteStrings.factKind, PaletteStrings.factWorkspace,
                                       PaletteStrings.factDirectory, PaletteStrings.factAgent, PaletteStrings.factSession,
                                       PaletteStrings.factStatus, PaletteStrings.factLastActive])
        #expect(Self.value(facts, PaletteStrings.factKind) == PaletteStrings.kindAgentChat)
        #expect(Self.value(facts, PaletteStrings.factDirectory) == "~/src/api")
        #expect(Self.value(facts, PaletteStrings.factStatus) == PaletteStrings.current)
        // The Cmd-P row carries the same facts, built when asked.
        let item = NavigationPaletteProvider.item(entry, recencyBoost: 0, source: nil)
        let readItemFacts = try #require(item.facts)
        #expect(Self.labels(readItemFacts()) == Self.labels(facts))
    }

    @Test func aTerminalAndABrowserTabSayTheirKind() {
        let terminal = PaletteFacts.tab(PaletteTab(id: "t1", title: "zsh", workspaceTitle: "api", kind: .terminal))
        let browser = PaletteFacts.navigation(PaletteNavigationEntry(id: "b1", kind: .tab(.browser), title: "Docs",
                                                                     url: "https://example.com/docs"), now: Self.now)
        #expect(Self.value(terminal, PaletteStrings.factKind) == PaletteStrings.kindTerminal)
        #expect(Self.value(terminal, PaletteStrings.factWorkspace) == "api")
        #expect(Self.value(browser, PaletteStrings.factKind) == PaletteStrings.kindBrowser)
        #expect(Self.value(browser, PaletteStrings.factAddress) == "https://example.com/docs")
    }

    @Test func aCommandListsItsShortcutCategoryAndDescription() {
        let facts = PaletteFacts.command(name: "Toggle Sidebar", keycaps: ["⌘", "B"], category: "View", description: "Shows the sidebar")
        #expect(facts == [PaletteFact(PaletteStrings.factCommand, "Toggle Sidebar"), PaletteFact(PaletteStrings.factShortcut, "⌘B"),
                          PaletteFact(PaletteStrings.factCategory, "View"), PaletteFact(PaletteStrings.factDescription, "Shows the sidebar")])
        // No shortcut and no description: no empty lines.
        #expect(Self.labels(PaletteFacts.command(name: "Reload", keycaps: nil, category: "View", description: " "))
            == [PaletteStrings.factCommand, PaletteStrings.factCategory])
    }

    @Test func aRowWithoutFactsListsWhatItShows() {
        let item = PaletteItem(id: "x", title: "Something", subtitle: "a detail", accessory: "Kind", keycaps: ["⌘", "J"],
                               primary: PaletteCommand(id: "run", title: "Run", symbol: "return", effect: .perform {}))
        #expect(PaletteFacts.of(item) == [PaletteFact(PaletteStrings.factKind, "Kind"), PaletteFact(PaletteStrings.factDetails, "a detail"),
                                          PaletteFact(PaletteStrings.factShortcut, "⌘J")])
    }

    // MARK: Cmd-K

    /// A palette showing one row that runs a registry action, with the preview look on or off; `edited` records
    /// each shortcut edit Cmd-K starts.
    private static func palette(preview: Bool, edited: Box) async -> PaletteController {
        _ = NSApplication.shared
        var sources = PaletteSources()
        sources.experiments = { PaletteExperiments(preview: preview) }
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: sources, frecencyPersistence: nil)
        let item = PaletteItem(id: "action:toggleSidebar", title: "Toggle Sidebar", keycaps: ["⌘", "B"],
                               primary: PaletteCommand(id: "run", title: "Run", symbol: "return", effect: .perform {}),
                               secondary: [PaletteCommand(id: "editShortcut", title: "Edit Keyboard Shortcut…", symbol: "keyboard",
                                                          effect: .performKeepingOpen {})],
                               actionID: "toggleSidebar")
        palette.show(page: PalettePageSpec(id: "preview.test", title: "Commands", placeholder: "",
                                           providers: [StaticPaletteProvider(id: "preview.test", items: [item])]))
        await palette.model.settle()
        palette.model.onEditShortcut = { id in
            edited.ids.append(id)
            return true
        }
        return palette
    }

    @MainActor private final class Box {
        var ids: [ActionID] = []
    }

    @Test func cmdKMapsToToggleActions() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k",
                                                  isARepeat: false, keyCode: 40))
        #expect(PaletteKeyMap.isActionsKey(event))
        #expect(PaletteKeyMap.command(for: event, actionsMenuOpen: false, queryIsEmpty: true, registry: ActionRegistry.standard()) == .toggleActions)
    }

    @Test func cmdKOpensTheActionsMenuWithThePreviewOn() async throws {
        let edited = Box()
        let palette = await Self.palette(preview: true, edited: edited)
        defer { palette.closeForTest() }
        #expect(palette.model.experiments.preview)
        #expect(palette.model.selectedItem?.id == "action:toggleSidebar")
        #expect(palette.model.handle(.toggleActions))
        #expect(edited.ids.isEmpty)
        let menu = try #require(palette.model.actionsMenu)
        #expect(menu.itemID == "action:toggleSidebar")
        // The shortcut editor stays one step away, in the menu.
        #expect(menu.commands.map(\.id).contains("editShortcut"))
        // Cmd-K again closes it.
        #expect(palette.model.handle(.toggleActions))
        #expect(palette.model.actionsMenu == nil)
    }

    @Test func cmdKStillEditsTheShortcutWithThePreviewOff() async {
        let edited = Box()
        let palette = await Self.palette(preview: false, edited: edited)
        defer { palette.closeForTest() }
        #expect(!palette.model.experiments.preview)
        #expect(palette.model.handle(.toggleActions))
        #expect(edited.ids == ["toggleSidebar"])
        #expect(palette.model.actionsMenu == nil)
    }
}
