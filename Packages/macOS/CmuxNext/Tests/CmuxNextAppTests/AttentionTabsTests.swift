import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextRemote
import Foundation
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
            AgentPaneAttentionTabs.Item(tabId: AttentionTabsWatch.key(machine: "local", tab: tabs[2].id), reason: "Approve the deploy", workspaceTitle: "cmux next",
                                        tabTitle: "Vercel", atMs: 2_000),
            AgentPaneAttentionTabs.Item(tabId: AttentionTabsWatch.key(machine: "local", tab: tabs[0].id), reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                        tabTitle: "GitHub · Sign in", atMs: 1_000),
        ])
        tabs[2].applyState(SessionStateMirror.TabRecord(), progress: nil)
        #expect(AttentionTabsWatch.items(in: Self.local(store)).map(\.tabId) == [AttentionTabsWatch.key(machine: "local", tab: tabs[0].id)], "a cleared mark leaves the list")
    }

    private static func local(_ store: DaemonStore) -> [(WorkspaceModel, machine: String)] {
        store.workspaces.map { ($0, machine: "local") }
    }

    /// Tabs on two machines can share an id (a forked machine keeps its tab ids): each is its own
    /// row, and its key finds the tab on its own machine (Go to's lookup), never the other one.
    @Test func twoMachinesTabsWithOneIdAreTwoRowsThatFindTheirOwnTab() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-attention-tabs-remote-unused")),
                                    environment: { [:] })
        services.machines.add(ssh)
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_forked", title: "GitHub")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        for (store, name) in [(services.daemon.store, "here"), (ssh.daemon.store, "lab")] {
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: name, screens: [screen])]))
            let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
            tab.applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Log in on \(name)", atMs: 1_000)), progress: nil)
        }
        let items = AttentionTabsWatch.items(in: services.machines.allWorkspaces.map { ($0.0, machine: $0.1.machineID) })
        #expect(items.count == 2)
        #expect(Set(items.map(\.tabId)).count == 2, "two machines' rows share a key")
        for item in items {
            let found = try #require(AttentionTabsWatch.locate(item.tabId, in: services.machines.daemons))
            let tab = try #require(found.daemon.store.tab(idOrResource: found.tab))
            #expect(tab.attention?.reason == item.reason, "\(item.reason)'s row found the other machine's tab")
            #expect(item.tabId.utf8.count <= AgentPaneAttentionTabs.maximumTabID)
        }
        // Both machines' workspaces also share an id here (a cloned machine's state): windows find a
        // workspace by id alone, so Go to on the SSH row refuses rather than show this Mac's tab.
        let shared = AgentPaneAttentionTabs.shared
        let (savedItems, savedOnOpen) = (shared.items, shared.onOpen)
        defer { shared.items = savedItems; shared.onOpen = savedOnOpen }
        AppActions.bind(services)
        shared.items = items
        let lab = try #require(items.first { $0.reason == "Log in on lab" })
        let windowsBefore = services.windows.controllers.count
        #expect(!shared.open(lab.tabId), "Go to on the SSH row showed a tab although its workspace id is this Mac's too")
        #expect(services.windows.controllers.count == windowsBefore, "a refused Go to opened a window")
        let long = AttentionTabsWatch.key(machine: String(repeating: "m", count: 1_000), tab: "tab_forked")
        #expect(long.utf8.count <= AgentPaneAttentionTabs.maximumTabID, "a long machine id made a key Go to refuses")
        #expect(AttentionTabsWatch.locate("tab_forked", in: services.machines.daemons) == nil, "a bare tab id names no machine")
        #expect(AttentionTabsWatch.locate("0000000000000000/tab_forked", in: services.machines.daemons) == nil)
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
        #expect(shown == [AttentionTabsWatch.key(machine: "local", tab: tabs[0].id)])
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
