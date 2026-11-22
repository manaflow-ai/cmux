@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// The launch deferral through a real window: an agent chat in the pane
/// beside the focused terminal has no view until the launch reveals the pane
/// content, then its pane shows the chat's view.
@MainActor
@Suite struct AgentTabLaunchDeferralWiringTests {
    static let chat = "tab_" + String(repeating: "c", count: 32)

    /// One workspace split in two: a live terminal on the left (focused, the
    /// first pane) and an agent chat on the right.
    static func tree() throws -> DaemonTree {
        let record = AgentSessionRef(host: AgentTabFixture.host, session: "s-1")
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a07","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"type":"split","dir":"right","ratio":0.5,"a":{"type":"leaf","pane":3},"b":{"type":"leaf","pane":6}},
        "name":null,"panes":[{"active_tab":0,"id":3,"name":null,"tabs":[{"kind":"pty","surface":4,"dead":false,"title":"zsh"}]},
        {"active_tab":0,"id":6,"name":null,"tabs":[\(AgentTabFixture.tab(7, chat, record))]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    @Test func theChatBesideTheFocusedTerminalShowsItsViewOnceThePaneContentIsRevealed() async throws {
        let reveal = LaunchReveal(clock: ManualClock())
        let services = SidebarSnapshotFirstTests.services(file: nil, reveal: reveal)
        services.agentTabs.localHost = AgentTabFixture.host
        services.agentTabs.holdsTabs = { _ in true }
        services.agentTabs.reachable = { _ in true }
        let store = services.daemon.store
        store.apply(snapshot: try Self.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        defer { window.window?.close() }
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content?.panes.values.contains { $0.currentTabKey == Self.chat } == true }
        let chatPane = try #require(window.content?.panes.values.first { $0.currentTabKey == Self.chat })
        let focused = try #require(window.state.focus.state.pane)
        #expect(focused != chatPane.paneKey, "the terminal's pane has focus")

        #expect(services.agentTabs.existingView(Self.chat) == nil, "no web view before the first pane content")
        #expect(services.agentTabs.launchDeferred.contains(Self.chat))

        reveal.markReady(.pane)
        let view = try #require(services.agentTabs.existingView(Self.chat), "the reveal makes the chat's view")
        #expect(view.isDescendant(of: chatPane.view), "its pane shows it")
        #expect(services.agentTabs.launchDeferred.isEmpty)
    }
}
