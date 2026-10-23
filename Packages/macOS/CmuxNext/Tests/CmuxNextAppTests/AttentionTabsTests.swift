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
        let items = AttentionTabsWatch.items(in: store.workspaces)
        #expect(items == [
            AgentPaneAttentionTabs.Item(tabId: tabs[2].id, reason: "Approve the deploy", workspaceTitle: "cmux next", tabTitle: "Vercel", atMs: 2_000),
            AgentPaneAttentionTabs.Item(tabId: tabs[0].id, reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                        tabTitle: "GitHub · Sign in", atMs: 1_000),
        ])
        tabs[2].applyState(SessionStateMirror.TabRecord(), progress: nil)
        #expect(AttentionTabsWatch.items(in: store.workspaces).map(\.tabId) == [tabs[0].id], "a cleared mark leaves the list")
    }

    @Test func thePaletteListsEachMarkAndItsRowJumpsToTheTab() async throws {
        let (store, tabs) = try Self.workspaces()
        let shared = AgentPaneAttentionTabs()
        shared.items = AttentionTabsWatch.items(in: store.workspaces)
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
        #expect(shown == [tabs[0].id])
    }

    @Test func anAgentsRunOpensNoPalette() throws {
        _ = NSApplication.shared
        let shared = AgentPaneAttentionTabs.shared
        let (items, onOpen) = (shared.items, shared.onOpen)
        defer { shared.items = items; shared.onOpen = onOpen }
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        shared.items = [AgentPaneAttentionTabs.Item(tabId: "tab_1", reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                                    tabTitle: "GitHub", atMs: 1_000)]
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform(AttentionPalettePage.id, invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == AttentionPaletteStrings.needsFocus, "an agent's run must not take the person's focus")
    }

    @Test func theActionIsInThePaletteAndTakesNoKey() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == AttentionPalettePage.id })
        #expect(descriptor.isPaletteVisible)
        #expect(descriptor.defaultShortcut == nil, "Go to What Needs Me takes no default key")
    }
}
