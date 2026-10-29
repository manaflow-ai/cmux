import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// Cmd-P finds a Chief subagent's workspace by the short id the Chief names it with
/// (Lawrence 2026-10-23, msg 11943: "a612" listed a212, a162, a112 and a compare URL; "612" listed
/// about:blank chat rows; the real a612 workspace never showed). The id is the whole query, or its
/// digits: that row goes first, above every fuzzy match of the id's letters.
@MainActor
@Suite(.paletteRanker)
struct PaletteAgentIDSearchTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = []
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    @MainActor private final class Navigation: PaletteNavigationSource {
        var entries: [PaletteNavigationEntry] = []
        func navigationEntries() -> [PaletteNavigationEntry] { entries }
        func open(_ entry: PaletteNavigationEntry) {}
    }

    /// The screenshot's rows: older Chief workspaces whose names start with their id, a compare
    /// URL, chat tabs whose session ids hold the digits, and the a612 workspace, named by its task.
    private static func palette() -> PaletteController {
        _ = NSApplication.shared
        let workspaces = Workspaces()
        workspaces.workspaces = [
            PaletteWorkspace(id: "w212", title: "a212 · Chief agents", groupName: "Chief agents", agentID: "a212"),
            PaletteWorkspace(id: "w162", title: "a162 · Cmd-T tabs self-close", agentID: "a162"),
            PaletteWorkspace(id: "w112", title: "a112 · cmux WireGuard mesh", agentID: "a112"),
            PaletteWorkspace(id: "w161", title: "a161 · deploy guard", agentID: "a161"),
            PaletteWorkspace(id: "w156", title: "a156 · a6 parity", agentID: "a156"),
            PaletteWorkspace(id: "wcmp", title: "github.com/manaflow-ai/cmux/compare/a612b0c...a612d00"),
            PaletteWorkspace(id: "w612", title: "Markdown pane omnibar back", groupName: "cmux-next app", agentID: "a612"),
        ]
        let navigation = Navigation()
        navigation.entries = [
            PaletteNavigationEntry(id: "t1", kind: .tab(.agentChat), title: "Cmd-T tabs self-close", workspaceTitle: "a162",
                                   sessionID: "acp:01a16c0a-6120-7f80-8aee-aeac17612612"),
            PaletteNavigationEntry(id: "t2", kind: .tab(.agentChat), title: "cmux WireGuard mesh", workspaceTitle: "a112",
                                   sessionID: "acp:01a16c0a-3242-7f80-8aee-612cac178a39"),
        ]
        return PaletteController(registry: ActionRegistry.standard(),
                                 sources: PaletteSources(workspaces: workspaces, navigation: navigation), frecencyPersistence: nil)
    }

    private static func search(_ palette: PaletteController, _ query: String) async -> [String] {
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        return palette.model.rows.map(\.item.id)
    }

    @Test(arguments: ["a612", "A612", " a612 ", "612"])
    func theSubagentIDPutsItsWorkspaceFirst(query: String) async {
        let palette = Self.palette()
        palette.show(.workspaces)
        let ids = await Self.search(palette, query)
        #expect(ids.first == "workspace:w612", "\(query): \(ids.prefix(5))")
    }

    @Test func anotherSubagentsIDNeverOutranksTheExactOne() async {
        let palette = Self.palette()
        palette.show(.workspaces)
        let ids = await Self.search(palette, "a612")
        let exact = ids.firstIndex(of: "workspace:w612")
        for other in ["workspace:w212", "workspace:w162", "workspace:w112", "workspace:w161", "workspace:w156"] {
            guard let at = ids.firstIndex(of: other) else { continue }
            #expect(exact.map { $0 < at } == true, "\(other) ranked above a612: \(ids.prefix(5))")
        }
        #expect(await Self.search(palette, "a212").first == "workspace:w212")
        #expect(await Self.search(palette, "162").first == "workspace:w162")
    }

    @Test func theCommandPaletteFindsItToo() async {
        let palette = Self.palette()
        palette.show(.commands)
        #expect(await Self.search(palette, "a612").first == "workspace:w612")
    }

    @Test func theRowNamesTheIDBeforeItsGroup() {
        let workspaces = Workspaces()
        workspaces.workspaces = [PaletteWorkspace(id: "w612", title: "Markdown pane omnibar back", directory: "/Users/me/fun/cmux",
                                                  groupName: "cmux-next app", agentID: "a612")]
        let item = WorkspacePaletteProvider(source: workspaces, showsItemsForEmptyQuery: true).makeItems()[0]
        #expect(item.subtitle?.hasPrefix("a612 · cmux-next app") == true, "\(item.subtitle ?? "nil")")
        #expect(item.handles == ["a612"])
    }
}
