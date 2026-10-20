import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Cmd-P opens the merged Search window (plans/cmux-next/search-everything-DESIGN.md section 10;
/// Lawrence 2026-10-20: "Cmd+P should also open the merged search-everything window"). The old
/// Cmd-P (Go to Workspace) stays its first results, so nothing regresses: before typing, the
/// workspaces show as before; typed, the same rows plus everything else. Cmd-Shift-P stays the
/// command palette.
@MainActor
@Suite(.paletteRanker)
struct CmdPOpensSearchTests {
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
        let sources = PaletteSources(workspaces: workspaces, navigation: Navigation())
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return (palette, registry)
    }

    /// Cmd-P (`goToWorkspace` with no workspace) opens the Search scope, not the Workspaces page.
    @Test func cmdPOpensTheSearchScope() async {
        let (palette, registry) = Self.palette()
        defer { palette.hide() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        #expect(palette.isVisible)
        #expect(palette.model.nav.levels.last?.scope == PaletteScopeID.search,
                "scope: \(String(describing: palette.model.nav.levels.last?.scope))")
        #expect(palette.model.pageTitle == PaletteStrings.searchEverythingTitle)
    }

    /// Before typing, Search lists the workspaces, as Cmd-P always did.
    @Test func theEmptyQueryKeepsTheWorkspaceList() async {
        let (palette, _) = Self.palette()
        defer { palette.hide() }
        palette.show(scope: PaletteScopeID.search)
        await palette.model.settle()
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.isSuperset(of: ["workspace:w1", "workspace:w2"]), "rows: \(ids)")
    }

    /// Typed, Search still finds Cmd-P's rows (workspaces, tabs) and Return still goes there.
    @Test func typedQueriesKeepCmdPRows() async {
        let workspaces = Workspaces()
        let (palette, registry) = Self.palette(workspaces: workspaces)
        defer { palette.hide() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: [:], origin: .user))
        palette.model.send(.setQuery("zebra"))
        await palette.model.settle()
        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.contains("workspace:w1") && ids.contains("tab:t1"), "rows: \(ids)")
        if let row = palette.model.rows.first(where: { $0.item.id == "workspace:w1" }) {
            palette.model.run(row.item.primary, of: row.item)
        }
        #expect(workspaces.selected == ["w1"])
    }

    /// With a workspace argument (a row's ref, the CLI) Go to Workspace still switches to it.
    @Test func goToWorkspaceWithAWorkspaceStillSwitches() async {
        let workspaces = Workspaces()
        let (palette, registry) = Self.palette(workspaces: workspaces)
        defer { palette.hide() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: ["workspace": .string("w2")], origin: .user))
        #expect(workspaces.selected == ["w2"])
        #expect(!palette.isVisible)
    }

    /// Search is the scope Cmd-P opens (its shortcut shows on the Search row); Cmd-Shift-P stays commands.
    @Test func searchIsTheScopeCmdPOpens() {
        let (palette, registry) = Self.palette()
        defer { palette.hide() }
        let search = palette.scopeDescriptors().first { $0.id == PaletteScopeID.search }
        #expect(search?.openAction == "goToWorkspace")
        #expect(registry.descriptor(for: "commandPalette")?.defaultShortcut == Shortcut("p", modifiers: [.command, .shift]))
        #expect(registry.descriptor(for: "goToWorkspace")?.defaultShortcut == Shortcut("p", modifiers: [.command]))
    }
}
