import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPalette
import Testing

/// tab-attention-v1's two ways to the tab: Needs you's `tab` items and the palette's Go to What
/// Needs Me list each marked tab by the agent's reason, its workspace and its title (never an
/// id), newest first; a row jumps through the one shared Go to. A mark alone moves nothing.
@MainActor @Suite(.serialized)
struct AttentionTabsTests {
    private static func workspaces() throws -> (DaemonStore, [TabModel]) {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "GitHub · Sign in"), TabSnapshot(surface: 2, title: "zsh"),
                                              TabSnapshot(surface: 3, title: "Vercel")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "cmux next", screens: [screen])]))
        let tabs = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs)
        tabs[0].applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Log in to GitHub", atMs: 1_000)), progress: nil)
        tabs[2].applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Approve the deploy", atMs: 2_000)), progress: nil)
        return (store, tabs)
    }

    @Test func onlyMarkedTabsAreListedNewestFirstByTheirTitles() throws {
        let (store, tabs) = try Self.workspaces()
        let items = AttentionTabsWatch.items(in: Self.local(store))
        #expect(items == [
            AgentPaneAttentionTabs.Item(tabId: "local/\(tabs[2].id)", reason: "Approve the deploy", workspaceTitle: "cmux next",
                                        tabTitle: "Vercel", atMs: 2_000),
            AgentPaneAttentionTabs.Item(tabId: "local/\(tabs[0].id)", reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                        tabTitle: "GitHub · Sign in", atMs: 1_000),
        ])
        tabs[2].applyState(SessionStateMirror.TabRecord(), progress: nil)
        #expect(AttentionTabsWatch.items(in: Self.local(store)).map(\.tabId) == ["local/\(tabs[0].id)"], "a cleared mark leaves the list")
    }

    private static func local(_ store: DaemonStore) -> [(WorkspaceModel, machine: String)] {
        store.workspaces.map { ($0, machine: "local") }
    }

    /// Tabs on two machines can share an id (a forked machine keeps its tab ids): each is its own
    /// row, and its key names its machine, so Go to shows that machine's tab and no other.
    @Test func twoMachinesTabsWithOneIdAreTwoRowsThatNameTheirMachine() throws {
        let (here, hereTabs) = try Self.workspaces()
        let (there, thereTabs) = try Self.workspaces()
        #expect(hereTabs[0].id == thereTabs[0].id)
        let items = AttentionTabsWatch.items(in: Self.local(here) + there.workspaces.map { ($0, machine: "ssh-lab") })
        #expect(items.count == 4)
        #expect(Set(items.map(\.tabId)).count == 4, "two machines' rows share a key")
        let split = try #require(AttentionTabsWatch.split(AttentionTabsWatch.key(machine: "ssh-lab", tab: thereTabs[0].id)))
        #expect(split.machine == "ssh-lab" && split.tab == thereTabs[0].id)
        #expect(AttentionTabsWatch.split(thereTabs[0].id) == nil, "a bare tab id names no machine")
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(!services.revealTab(thereTabs[0].id, onMachine: "ssh-lab"), "a machine that is not connected shows nothing")
    }

    @Test func thePaletteListsEachMarkAndItsRowJumpsToTheTab() async throws {
        let (store, tabs) = try Self.workspaces()
        let shared = AgentPaneAttentionTabs()
        shared.items = AttentionTabsWatch.items(in: Self.local(store))
        var shown: [String] = []
        shared.onOpen = { id in shown.append(id); return true }
        let page = AttentionPalettePage(tabs: shared).page()
        #expect(page.id == "attention")
        var rows: [PaletteItem] = []
        for provider in page.providers { rows += await provider.items() }
        #expect(rows.map(\.title) == ["Approve the deploy", "Log in to GitHub"])
        #expect(rows.map(\.subtitle) == ["cmux next · Vercel", "cmux next · GitHub · Sign in"])
        #expect(rows.allSatisfy { !($0.subtitle ?? "").contains("tab_") && !$0.title.contains("tab_") }, "no id is shown")
        guard case .perform(let run) = try #require(rows.last).primary.effect else {
            Issue.record("a row jumps to its tab")
            return
        }
        #expect(shown.isEmpty, "listing jumps nowhere")
        run()
        #expect(shown == ["local/\(tabs[0].id)"])
    }

    @Test func anAgentsRunOpensNoPalette() throws {
        _ = NSApplication.shared
        let shared = AgentPaneAttentionTabs.shared
        let (items, onOpen, onChange) = (shared.items, shared.onOpen, shared.onChange)
        defer { shared.items = items; shared.onOpen = onOpen; shared.onChange = onChange }
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        shared.items = [AgentPaneAttentionTabs.Item(tabId: "tab_1", reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                                    tabTitle: "GitHub", atMs: 1_000)]
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform(AttentionPalettePage.id, invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == AttentionPaletteStrings.needsFocus, "an agent's run must not take the person's focus")
    }

    /// The page reads the marks at each load, so an open page's reload on a change drops a
    /// cleared mark's row and shows a new one.
    @Test func thePagesRowsFollowTheMarks() throws {
        let tabs = AgentPaneAttentionTabs()
        let provider = try #require(AttentionPalettePage(tabs: tabs).page().providers.first)
        #expect(provider.immediateItems?.isEmpty == true)
        tabs.items = [AgentPaneAttentionTabs.Item(tabId: "tab_1", reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                                  tabTitle: "GitHub", atMs: 1_000)]
        #expect(provider.immediateItems?.map(\.title) == ["Log in to GitHub"], "a new mark is missing from the open page")
        tabs.items = []
        #expect(provider.immediateItems?.isEmpty == true, "a cleared mark's row stayed on the open page")
    }

    /// The App reloads an open Go to What Needs Me page when the marks change: the person's query
    /// and the page stay, a new mark's row comes and a cleared mark's row goes.
    @Test func anOpenPageReloadsOnAChangeAndKeepsItsQuery() async throws {
        _ = NSApplication.shared
        let shared = AgentPaneAttentionTabs.shared
        let (items, onOpen, onChange) = (shared.items, shared.onOpen, shared.onChange)
        defer { shared.items = items; shared.onOpen = onOpen; shared.onChange = onChange }
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let palette = services.palette
        defer { palette.hide() }
        let github = AgentPaneAttentionTabs.Item(tabId: "local/tab_1", reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                                 tabTitle: "GitHub", atMs: 1_000)
        let vercel = AgentPaneAttentionTabs.Item(tabId: "local/tab_2", reason: "Log in to Vercel", workspaceTitle: "Release",
                                                 tabTitle: "Vercel", atMs: 2_000)
        shared.items = [github]
        palette.model.reset(to: AttentionPalettePage().page())
        palette.model.query = "log in"
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.title) == ["Log in to GitHub"])
        shared.items = [vercel, github]
        await palette.model.settle()
        #expect(palette.model.currentPageID == AttentionPalettePage.pageID, "the reload left the page")
        #expect(palette.model.query == "log in", "the reload dropped the query")
        #expect(Set(palette.model.rows.map(\.item.title)) == ["Log in to GitHub", "Log in to Vercel"], "a new mark is missing")
        shared.items = [vercel]
        await palette.model.settle()
        #expect(palette.model.rows.map(\.item.title) == ["Log in to Vercel"], "a cleared mark's row stayed on the open page")
    }

    @Test func theActionIsInThePaletteAndTakesNoKey() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == AttentionPalettePage.id })
        #expect(descriptor.isPaletteVisible)
        #expect(descriptor.defaultShortcut == nil, "Go to What Needs Me takes no default key")
    }
}
