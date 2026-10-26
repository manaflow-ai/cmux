import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// The sidebar's Search button (plans/cmux-next/sidebar-search.md; Lawrence 2026-10-20: "a search
/// icon button ... it should search through all types of stuff"): one palette scope, `search`,
/// whose page searches workspaces, groups, panes and tabs, settings, commands and the App's
/// contributed pages (history, agent chats) with the palette's one ranker, rows grouped by type.
@MainActor
@Suite(.paletteRanker)
struct PaletteSearchScopeTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "w1", title: "Zebra backend"), PaletteWorkspace(id: "w2", title: "Docs")]
        var selected: [String] = []
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    @MainActor private final class Navigation: PaletteNavigationSource {
        var entries: [PaletteNavigationEntry] = [
            PaletteNavigationEntry(id: "t1", kind: .tab(.browser), title: "Zebra docs", workspaceTitle: "Docs",
                                   url: "https://zebra.example.com/"),
            PaletteNavigationEntry(id: "t2", kind: .tab(.terminal), title: "zebra-server", workspaceTitle: "Zebra backend"),
        ]
        func navigationEntries() -> [PaletteNavigationEntry] { entries }
        func open(_ entry: PaletteNavigationEntry) {}
    }

    @MainActor private final class Settings: PaletteSettingsSource {
        var rows: [PaletteSettingRow] = [
            PaletteSettingRow(id: "zebra.stripes", title: "Zebra Stripes", group: "Appearance", value: "Off", kind: .toggle(isOn: false)),
        ]
        func preview(row: String, option: String?) {}
        func commit(row: String, option: String) {}
        func commit(row: String, text: String) {}
    }

    private static func palette(workspaces: Workspaces = Workspaces()) -> PaletteController {
        _ = NSApplication.shared
        var sources = PaletteSources(workspaces: workspaces, navigation: Navigation(), settings: Settings())
        // An App page that joins Search (browser history here) with rows that carry no section.
        let visit = PaletteItem(id: "history:zebra", title: "Zebra wiki", subtitle: "zebra.wiki",
                                primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}))
        sources.searchContributions = [
            PaletteSearchContribution(id: "history", title: "History", order: 40) {
                PalettePageSpec(id: "history.search", title: "History", placeholder: "",
                                providers: [StaticPaletteProvider(id: "history.search", items: [visit])])
            },
        ]
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return palette
    }

    private static func search(_ palette: PaletteController, _ query: String) async {
        palette.model.send(.setQuery(query))
        await palette.model.settle()
    }

    /// The scope opens a page of its own, titled Search, with the all-kinds placeholder.
    @Test func theSearchScopeOpensTheSearchPage() async {
        let palette = Self.palette()
        defer { palette.hide() }
        #expect(palette.show(scope: PaletteScopeID.search))
        await palette.model.settle()
        #expect(palette.model.pageTitle == PaletteStrings.searchEverythingTitle)
        #expect(palette.model.placeholder == PaletteStrings.searchEverythingPlaceholder)
        #expect(palette.model.breadcrumbs.last == PaletteStrings.searchEverythingTitle)
        // The scope is in the catalog agents read (`palette.scopes`) and the `?` list.
        #expect(palette.scopeDescriptors().contains { $0.id == PaletteScopeID.search })
    }

    /// One query finds every kind, each kind in its own section (not one merged list).
    @Test func oneQuerySearchesEveryKindGroupedByType() async {
        let palette = Self.palette()
        defer { palette.hide() }
        palette.show(scope: PaletteScopeID.search)
        await Self.search(palette, "zebra")

        let ids = Set(palette.model.rows.map(\.item.id))
        #expect(ids.contains("workspace:w1"), "workspace: \(ids)")
        #expect(ids.contains("tab:t1"), "browser tab by title and URL: \(ids)")
        #expect(ids.contains("tab:t2"), "terminal tab: \(ids)")
        #expect(ids.contains { $0.hasPrefix("setting:") }, "setting: \(ids)")
        #expect(ids.contains("history:zebra"), "contributed history page: \(ids)")

        let titles = palette.model.sections.map(\.title)
        #expect(titles.contains(PaletteStrings.sectionWorkspaces), "sections: \(titles)")
        #expect(titles.contains(PaletteStrings.sectionTabs), "sections: \(titles)")
        #expect(titles.contains("History"), "a contributed row with no section takes its contribution's: \(titles)")
        #expect(!titles.contains(""), "no untitled merged block: \(titles)")
        // Each id is listed once.
        #expect(palette.model.rows.count == Set(palette.model.rows.map(\.item.id)).count)
    }

    /// Commands are found too, the same rows as Cmd-Shift-P.
    @Test func commandsAreSearchedToo() async {
        let palette = Self.palette()
        defer { palette.hide() }
        palette.show(scope: PaletteScopeID.search)
        await Self.search(palette, "Search Keyboard Shortcuts")
        #expect(palette.model.rows.contains { $0.item.actionID == "palette.searchShortcuts" },
                "rows: \(palette.model.rows.map(\.item.id))")
    }

    /// Return on a row goes there through its source.
    @Test func returnFocusesTheRow() async {
        let workspaces = Workspaces()
        let palette = Self.palette(workspaces: workspaces)
        defer { palette.hide() }
        palette.show(scope: PaletteScopeID.search)
        await Self.search(palette, "Zebra backend")
        let row = palette.model.rows.first { $0.item.id == "workspace:w1" }
        #expect(row != nil)
        if let row { palette.model.run(row.item.primary, of: row.item) }
        #expect(workspaces.selected == ["w1"])
    }

    /// Backspace on the empty query leaves Search for the full palette.
    @Test func backspaceOnEmptyReturnsToTheRoot() async {
        let palette = Self.palette()
        defer { palette.hide() }
        palette.show(scope: PaletteScopeID.search)
        await palette.model.settle()
        palette.model.send(.backspaceOnEmpty)
        await palette.model.settle()
        #expect(palette.model.nav.levels.count == 1)
    }
}
