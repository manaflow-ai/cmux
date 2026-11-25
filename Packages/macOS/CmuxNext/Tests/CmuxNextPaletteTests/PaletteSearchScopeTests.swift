import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// The sidebar's Search button (plans/cmux-next/sidebar-search.md; Lawrence 2026-10-20: "a search
/// icon button ... it should search through all types of stuff"): one palette scope, `search`,
/// whose page searches workspaces, groups, panes and tabs, settings, commands and the App's
/// contributed pages (history, agent chats) with the palette's one ranker, rows grouped by type.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
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
        defer { palette.closeForTest() }
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
        defer { palette.closeForTest() }
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
        defer { palette.closeForTest() }
        palette.show(scope: PaletteScopeID.search)
        await Self.search(palette, "Search Keyboard Shortcuts")
        #expect(palette.model.rows.contains { $0.item.actionID == "palette.searchShortcuts" },
                "rows: \(palette.model.rows.map(\.item.id))")
    }

    /// Return on a row goes there through its source.
    @Test func returnFocusesTheRow() async {
        let workspaces = Workspaces()
        let palette = Self.palette(workspaces: workspaces)
        defer { palette.closeForTest() }
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
        defer { palette.closeForTest() }
        palette.show(scope: PaletteScopeID.search)
        await palette.model.settle()
        palette.model.send(.backspaceOnEmpty)
        await palette.model.settle()
        #expect(palette.model.nav.levels.count == 1)
    }
}

/// The palette v2 scope bar (`PaletteV2Look.scoped`): This Workspace and Sessions narrow Go to Workspace's entries,
/// and typed tokens ("Session contains: X", "Workspace contains: X") narrow the ranked rows (`PaletteScopeFilter`).
@MainActor
@Suite
struct PaletteScopeBarFilterTests {
    private static let entries: [PaletteNavigationEntry] = [
        PaletteNavigationEntry(id: "g1", kind: .group(workspaceCount: 2), title: "Backend"),
        PaletteNavigationEntry(id: "p1", kind: .pane, title: "Left", workspaceTitle: "API", workspaceID: "w1"),
        PaletteNavigationEntry(id: "t1", kind: .tab(.agentChat), title: "Design review", workspaceTitle: "API", workspaceID: "w1"),
        PaletteNavigationEntry(id: "t2", kind: .tab(.terminal), title: "server", workspaceTitle: "Docs", workspaceID: "w2"),
    ]

    private static func row(_ id: String, _ title: String, _ subtitle: String? = nil) -> PaletteRow {
        PaletteRow(item: PaletteItem(id: id, title: title, subtitle: subtitle,
                                     primary: PaletteCommand(id: "open", title: "Open", effect: .perform {})),
                   highlights: [], score: 0)
    }

    private static func ids(_ sections: [PaletteResultSection]) -> [String] { sections.flatMap(\.rows).map(\.id) }

    @Test func sessionsKeepPanesAndTabsButNoGroup() {
        #expect(PaletteScopeFilter.sessionEntries(Self.entries).map(\.id) == ["p1", "t1", "t2"])
    }

    @Test func thisWorkspaceKeepsOnlyItsPanesAndTabs() {
        #expect(PaletteScopeFilter.entries(Self.entries, inWorkspace: "w1").map(\.id) == ["p1", "t1"])
        #expect(PaletteScopeFilter.entries(Self.entries, inWorkspace: "w2").map(\.id) == ["t2"])
        // No workspace captured on open: no session row claims to be in it.
        #expect(PaletteScopeFilter.entries(Self.entries, inWorkspace: nil).isEmpty)
    }

    @Test func aSessionTokenMatchesTitlesAndAWorkspaceTokenSubtitles() {
        let sections = [
            PaletteResultSection(section: TabPaletteProvider.section, rows: [
                Self.row("t1", "Design review", "API · ~/src/api"),
                Self.row("t2", "server", "Docs"),
                Self.row("t3", "docs build", "API"),
            ]),
            PaletteResultSection(section: NavigationPaletteProvider.paneSection, rows: [Self.row("p1", "Left", "Docs")]),
        ]
        let session = PaletteScopeToken(kind: .session, text: "DESIGN")
        let workspace = PaletteScopeToken(kind: .workspace, text: "docs")
        #expect(Self.ids(PaletteScopeFilter.filtered(sections, tokens: [session])) == ["t1"])
        // "docs build" has the word in its title, not its workspace: the workspace token leaves it out.
        #expect(Self.ids(PaletteScopeFilter.filtered(sections, tokens: [workspace])) == ["t2", "p1"])
        // Tokens add up; a section left with no row is dropped.
        let both = PaletteScopeFilter.filtered(sections, tokens: [workspace, PaletteScopeToken(kind: .session, text: "serv")])
        #expect(Self.ids(both) == ["t2"])
        #expect(both.count == 1)
        #expect(Self.ids(PaletteScopeFilter.filtered(sections, tokens: [])) == ["t1", "t2", "t3", "p1"])
    }

    @Test func suggestionRowsSurviveTheTokens() {
        let suggestion = PaletteScopeFilter.suggestionRow(PaletteScopeToken(kind: .workspace, text: "zzz")) {}
        let sections = [PaletteResultSection(section: PaletteScopeFilter.suggestionsSection, rows: [suggestion]),
                        PaletteResultSection(section: TabPaletteProvider.section, rows: [Self.row("t1", "Design")])]
        let filtered = PaletteScopeFilter.filtered(sections, tokens: [PaletteScopeToken(kind: .session, text: "nothing")])
        #expect(Self.ids(filtered) == [suggestion.id])
    }

    @Test func aTypedQueryOffersOneTokenPerKindWithTheTextEmphasized() {
        #expect(PaletteScopeFilter.suggestions(for: "  ").isEmpty)
        let tokens = PaletteScopeFilter.suggestions(for: " Design ")
        #expect(tokens == [PaletteScopeToken(kind: .session, text: "Design"), PaletteScopeToken(kind: .workspace, text: "Design")])
        let row = PaletteScopeFilter.suggestionRow(tokens[0]) {}
        #expect(row.item.title == PaletteStrings.sessionContains + " Design")
        // Only the typed text draws in the primary color; the "Session contains:" lead stays muted.
        let lead = (PaletteStrings.sessionContains + " ").unicodeScalars.count
        #expect(row.highlights == Array(lead..<lead + 6))
        // A suggestion is made from the query: never a use to remember.
        #expect(row.item.frecencyKey == nil)
    }

    @Test func eachSegmentIsAScopeOfTheStack() {
        for segment in PaletteScopeSegment.allCases {
            #expect(PaletteScopeSegment(exactly: segment.scope) == segment)
        }
        #expect(PaletteScopeSegment(exactly: nil) == .all)
        #expect(PaletteScopeSegment(exactly: PaletteScopeID.search) == nil)
    }
}
