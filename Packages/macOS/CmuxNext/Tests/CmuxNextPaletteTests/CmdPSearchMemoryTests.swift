import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-P remembers what the person picks, as Raycast does (Lawrence 2026-11-05: "after i search for
/// something and select it, it should be prioritized"; "account for how far up the sidebar
/// something is, but also based on history"). One score for every row: the match class first,
/// then inside a class the learned pick for the typed query start (strongest), the frecency of
/// the row across all queries, and the row's place in the sidebar (higher ranks higher).
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct CmdPSearchMemoryTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace]
        var selected: [String] = []
        init(_ workspaces: [PaletteWorkspace]) { self.workspaces = workspaces }
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    @MainActor private final class Settings {
        var value = PaletteRankSettings()
    }

    /// Three equal matches for "api" (same match class, same length), listed in the daemon's order
    /// but drawn in another order in the sidebar: server at the top, worker 4th, client 8th.
    private static func workspaces() -> Workspaces {
        Workspaces([
            PaletteWorkspace(id: "client", title: "api client", sidebarRank: 7),
            PaletteWorkspace(id: "server", title: "api server", sidebarRank: 0),
            PaletteWorkspace(id: "worker", title: "api worker", sidebarRank: 3),
        ])
    }

    private static func palette(_ workspaces: Workspaces, settings: Settings = Settings()) -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        var sources = PaletteSources(workspaces: workspaces)
        sources.rankSettings = { settings.value }
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return (palette, registry)
    }

    /// Opens Cmd-P, types `query` and returns the workspace rows in display order.
    private static func search(_ palette: PaletteController, _ registry: ActionRegistry, _ query: String) async -> [String] {
        if palette.isVisible { palette.hide() }
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settle()
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        return palette.model.rows.map(\.item.id).filter { $0.hasPrefix("workspace:") }
    }

    /// Runs the row `id` from the current results, as Return on it does.
    private static func pick(_ palette: PaletteController, _ id: String) {
        guard let row = palette.model.rows.first(where: { $0.item.id == id }) else {
            Issue.record("no row \(id) in \(palette.model.rows.map(\.item.id))")
            return
        }
        palette.model.run(row.item.primary, of: row.item)
    }

    @Test func higherInTheSidebarRanksFirstAmongEqualMatches() async {
        let (palette, registry) = Self.palette(Self.workspaces())
        defer { palette.closeForTest() }
        let typed = await Self.search(palette, registry, "api")
        #expect(typed == ["workspace:server", "workspace:worker", "workspace:client"])
        let empty = await Self.search(palette, registry, "")
        #expect(empty == ["workspace:server", "workspace:worker", "workspace:client"])
    }

    /// The Raycast bar: the row picked for a query comes first the next time that query, or a
    /// shorter start of it, is typed, over a row higher in the sidebar.
    @Test func aRowPickedForAQueryComesFirstForThatQueryNextTime() async {
        let workspaces = Self.workspaces()
        let (palette, registry) = Self.palette(workspaces)
        defer { palette.closeForTest() }
        _ = await Self.search(palette, registry, "api")
        Self.pick(palette, "workspace:client")
        #expect(workspaces.selected == ["client"])

        #expect(await Self.search(palette, registry, "api").first == "workspace:client")
        #expect(await Self.search(palette, registry, "ap").first == "workspace:client")
        // A query the pick does not start finds its own rows.
        #expect(await Self.search(palette, registry, "worker") == ["workspace:worker"])
    }

    /// Frecency counts across every query: a row run under another query outranks a row higher in
    /// the sidebar for an equal match.
    @Test func useUnderAnyQueryOutranksSidebarPlace() async {
        let (palette, registry) = Self.palette(Self.workspaces())
        defer { palette.closeForTest() }
        _ = await Self.search(palette, registry, "client")
        Self.pick(palette, "workspace:client")
        #expect(await Self.search(palette, registry, "api").first == "workspace:client")
    }

    /// With `palette.searchHistory` off, nothing is learned and the sidebar order stands.
    @Test func searchHistoryOffNeitherLearnsNorRanksByHistory() async {
        let settings = Settings()
        settings.value.remembersSearches = false
        let (palette, registry) = Self.palette(Self.workspaces(), settings: settings)
        defer { palette.closeForTest() }
        _ = await Self.search(palette, registry, "api")
        Self.pick(palette, "workspace:client")
        #expect(await Self.search(palette, registry, "api") == ["workspace:server", "workspace:worker", "workspace:client"])
        #expect(palette.model.frecency.entries.isEmpty && palette.model.frecency.picks.isEmpty)
    }

    /// Clear Search History (`palette.clearSearchHistory`) forgets every use and learned pick.
    @Test func clearSearchHistoryForgetsEveryPick() async {
        let (palette, registry) = Self.palette(Self.workspaces())
        defer { palette.closeForTest() }
        _ = await Self.search(palette, registry, "api")
        Self.pick(palette, "workspace:client")
        #expect(await Self.search(palette, registry, "api").first == "workspace:client")
        palette.hide()

        #expect(registry.perform("palette.clearSearchHistory", invocation: ActionInvocation(arguments: [:], origin: .user)))
        #expect(palette.model.frecency.entries.isEmpty && palette.model.frecency.picks.isEmpty)
        #expect(await Self.search(palette, registry, "api") == ["workspace:server", "workspace:worker", "workspace:client"])
    }

    /// A local history (an older daemon, tests) keeps its learned picks across launches.
    @Test func aLocalHistoryKeepsItsPicksAcrossLaunches() {
        final class Memory: FrecencyPersisting {
            var saved: FrecencyStore?
            func load() -> FrecencyStore? { saved }
            func save(_ store: FrecencyStore) {
                // Through JSON, as UserDefaults keeps it.
                saved = (try? JSONEncoder().encode(store)).flatMap { try? JSONDecoder().decode(FrecencyStore.self, from: $0) }
            }
        }
        let memory = Memory()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        LocalPaletteUsageStore(persistence: memory).recordUse(key: "workspace:client", query: "API  c", at: now)
        let relaunched = LocalPaletteUsageStore(persistence: memory)
        let prefixes = Set(relaunched.history.picks.filter { $0.key == "workspace:client" && $0.isLast }.map(\.prefix))
        #expect(prefixes == ["a", "ap", "api", "api c"])
    }
}
