import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// An agent chat in the GUI rings its pane when its turn ends, as a terminal agent's notification
/// does (Austin, 2026-10-20: "blue attention ring panes also over the GUI if they are finished").
/// acpmux reads a turn that ends in a shown chat at once (cx-n8ou), so no notification marks it;
/// the app keeps the ring until the person goes into the pane. Leo (2026-10-21): "the model
/// response does a double blue ring pulse", agreed not to be the default, so the ring is opt-in
/// (`notifications.attention.agentChats`) and themed like every attention ring.
@MainActor @Suite(.serialized)
struct AgentTurnRingTests {
    @Test func aTurnThatStopsWorkingReportsItsEnd() {
        let turns = AgentTurnStateStore()
        var ended: [String] = []
        turns.onTurnEnded = { ended.append($0) }
        turns.apply(session: "s1", state: .working, lastMessage: nil, muted: false, title: nil, detail: nil)
        turns.apply(session: "s1", state: nil, lastMessage: nil, muted: false, title: nil, detail: nil)
        #expect(ended == ["s1"])
        // The watch closing is not an end.
        turns.apply(session: "s2", state: .working, lastMessage: nil, muted: false, title: nil, detail: nil)
        turns.clearLive()
        #expect(ended == ["s1"], "the watch closing rang a chat")
    }

    /// Leo (2026-10-21): no blinky on turn end for the GUI by default. An agent chat's pane rings
    /// only with `notifications.attention.agentChats` on; off, a finished turn leaves no mark, and
    /// turning it off clears a ring already showing.
    @Test func aFinishedTurnRingsNothingByDefault() throws {
        _ = NSApplication.shared
        #expect(AttentionSettings().agentChatRing == .none, "agent chat panes ring by default")
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:ring", session: "s1", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        design.attention = AttentionSettings()
        let service = NotificationCenterService()
        service.agentTurnEnded(session: "s1", in: store.workspaces)
        #expect(service.agentFinished.isEmpty, "a finished turn was recorded for a ring by default")
        #expect(service.attentionMarks(for: workspace).isEmpty, "a finished reply rang its pane by default")
        design.attention.agentChatRing = .ring
        service.agentTurnEnded(session: "s1", in: store.workspaces)
        #expect(service.attentionMarks(for: workspace).count == 1, "the opt-in ring did not ring")
        design.attention.agentChatRing = .none
        #expect(service.attentionMarks(for: workspace).isEmpty, "turning agent chat rings off left the ring")
    }

    private static func chatTab() throws -> (NotificationCenterService, WorkspaceModel, TabModel) {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "chat")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        let service = NotificationCenterService()
        service.agentFinished[tab.id] = 1 << 62
        return (service, workspace, tab)
    }

    @Test func aFinishedChatRingsItsPane() throws {
        let (service, workspace, _) = try Self.chatTab()
        #expect(service.attentionMarks(for: workspace).count == 1, "the finished chat's pane has no ring")
    }

    @Test func focusAloneKeepsTheRingAndAClickBlinksItOut() throws {
        let (service, workspace, tab) = try Self.chatTab()
        service.interacted(.focus, tab: tab)
        #expect(service.attentionMarks(for: workspace).count == 1, "focus cleared the ring")
        service.interacted(.click, tab: tab)
        #expect(service.attentionMarks(for: workspace).isEmpty, "the click left the ring")
        #expect(service.entryReads.contains(tab.id), "the click's read would not blink the ring out")
    }

    @Test func markReadClearsTheRingWithoutTheFlash() throws {
        let (service, workspace, tab) = try Self.chatTab()
        service.acknowledge(tab)
        #expect(service.attentionMarks(for: workspace).isEmpty)
        #expect(!service.entryReads.contains(tab.id))
    }
}
