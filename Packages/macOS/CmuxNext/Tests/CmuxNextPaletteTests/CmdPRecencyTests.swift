import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// Cmd-P ranks by recency next to match quality and search memory (Lawrence 2026-11-07, a Cmd-P
/// shot of "cmux-tui" listing days-old a157/a158/a657 workspaces first and a workspace twice, as
/// itself and as its same-named terminal: "make sure we include recency into algorithm for
/// searching"). A row used recently wins equal and near matches, decaying with time; the row the
/// person is on gets no lift; a tab that only repeats its workspace's name is that workspace's row.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct CmdPRecencyTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace]
        init(_ workspaces: [PaletteWorkspace]) { self.workspaces = workspaces }
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static func palette(_ workspaces: Workspaces) -> (PaletteController, ActionRegistry) {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: workspaces), frecencyPersistence: nil)
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

    /// The shot's case: three equal matches, the days-old ones high in the sidebar, the one used two
    /// minutes ago at the bottom. The recent one comes first.
    @Test func aWorkspaceUsedMinutesAgoRanksFirstAmongEqualMatches() async {
        let now = Date()
        let (palette, registry) = Self.palette(Workspaces([
            PaletteWorkspace(id: "a157", title: "cmux-tui a157", sidebarRank: 0, lastUsed: now.addingTimeInterval(-3 * 86_400)),
            PaletteWorkspace(id: "a158", title: "cmux-tui a158", sidebarRank: 1),
            PaletteWorkspace(id: "fresh", title: "cmux-tui main", sidebarRank: 40, lastUsed: now.addingTimeInterval(-120)),
        ]))
        defer { palette.closeForTest() }
        #expect(await Self.search(palette, registry, "cmux-tui").first == "workspace:fresh")
    }

    /// Recency orders equal and near matches only: a better match class still wins.
    @Test func recencyNeverBeatsABetterMatch() async {
        let now = Date()
        let (palette, registry) = Self.palette(Workspaces([
            PaletteWorkspace(id: "fuzzy", title: "the deployment notes", sidebarRank: 0, lastUsed: now),
            PaletteWorkspace(id: "exact", title: "deploy", sidebarRank: 9),
        ]))
        defer { palette.closeForTest() }
        #expect(await Self.search(palette, registry, "deploy").first == "workspace:exact")
    }

    /// The workspace the person is on gets no recency lift: the one they came from comes first.
    @Test func theCurrentWorkspaceGetsNoRecencyLift() async {
        let now = Date()
        let (palette, registry) = Self.palette(Workspaces([
            PaletteWorkspace(id: "here", title: "api here", isSelected: true, sidebarRank: 0, lastUsed: now),
            PaletteWorkspace(id: "before", title: "api before", sidebarRank: 5, lastUsed: now.addingTimeInterval(-600)),
        ]))
        defer { palette.closeForTest() }
        #expect(await Self.search(palette, registry, "api") == ["workspace:before", "workspace:here"])
    }

    @Test func recencyDecaysByHalvesAndAddsAPlaceBoost() {
        let prior = PaletteRecencyPrior()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(prior.decay(lastUsed: now, now: now) == 32)
        #expect(prior.decay(lastUsed: now.addingTimeInterval(-6 * 3_600), now: now) == 16)
        #expect(prior.decay(lastUsed: now.addingTimeInterval(-7 * 86_400), now: now) == 0)
        #expect(prior.decay(lastUsed: nil, now: now) == 0)
        // A clock step back (a use stamped after now) counts as now, never more.
        #expect(prior.decay(lastUsed: now.addingTimeInterval(60), now: now) == 32)
        let biases = prior.biases([("old", now.addingTimeInterval(-86_400)), ("new", now.addingTimeInterval(-1)),
                                   ("new", now.addingTimeInterval(-500))], now: now)
        #expect(biases["new"] == 32 + 16)
        #expect(biases["old"] == prior.decay(lastUsed: now.addingTimeInterval(-86_400), now: now) + 14)
        #expect(biases["never"] == nil)
    }

    /// A workspace and its lone same-named terminal are one row: the shot listed "cmux-tui" twice.
    /// Two tabs that repeat the name stay, named by their kind (the ultra case).
    @Test func aTabThatAloneRepeatsItsWorkspaceNameIsThatWorkspacesRow() {
        let entries = [
            PaletteNavigationEntry(id: "t1", kind: .tab(.terminal), title: "cmux-tui", workspaceTitle: "cmux-tui", workspaceID: "w1"),
            PaletteNavigationEntry(id: "t2", kind: .tab(.terminal), title: "zsh", workspaceTitle: "cmux-tui", workspaceID: "w1"),
            PaletteNavigationEntry(id: "t3", kind: .tab(.agentChat), title: "web", workspaceTitle: "web", workspaceID: "w2"),
            PaletteNavigationEntry(id: "t4", kind: .tab(.terminal), title: "web", workspaceTitle: "web", workspaceID: "w2"),
        ]
        let items = NavigationPaletteProvider.items(entries, source: nil)
        #expect(items.map(\.id) == ["tab:t2", "tab:t3", "tab:t4"])
        #expect(items.map(\.title) == ["zsh", "Agent Chat", "Terminal"])
    }

    /// A tab used now ranks over its equal twin used yesterday, and the tab the person is on gets no lift.
    @Test func aTabsRecencyDecaysAndTheCurrentTabGetsNone() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let entries = [
            PaletteNavigationEntry(id: "here", kind: .tab(.terminal), title: "shell", isCurrent: true, lastUsed: now),
            PaletteNavigationEntry(id: "yesterday", kind: .tab(.terminal), title: "shell", lastUsed: now.addingTimeInterval(-86_400)),
            PaletteNavigationEntry(id: "recent", kind: .tab(.terminal), title: "shell", lastUsed: now.addingTimeInterval(-60)),
        ]
        let bias = Dictionary(uniqueKeysWithValues: NavigationPaletteProvider.items(entries, source: nil, now: now).map { ($0.id, $0.rankBias) })
        #expect(bias["tab:here"] == NavigationPaletteProvider.tabBias)
        #expect(bias["tab:recent"]! >= NavigationPaletteProvider.tabBias + 32 + 16 - 1)
        #expect(bias["tab:recent"]! - bias["tab:yesterday"]! > 20)
    }
}
