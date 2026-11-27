import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextSidebar
import Foundation
import Testing

@MainActor
struct SidebarPriorityOpenedSessionsTests {
    private func lane(_ id: String, requiresOpen: Bool) throws -> AgentActivityLane {
        try #require(AgentActivityLane.of(summary: [
            "sessionId": id,
            "workspaceId": "creation-time-binding",
            "lane": ["state": "input", "requiresOpen": requiresOpen],
        ]))
    }

    @Test func unopenedChildrenStayHiddenUntilOpenedOrPinned() throws {
        let store = AgentLaneStore()
        store.lanes = ["personal": try lane("personal", requiresOpen: false),
                       "child": try lane("child", requiresOpen: true)]
        let marks = AgentPriorityMarks(defaults: nil)
        let chats = AgentPriorityChats(marks: marks, stores: [store], checksFailing: { _ in false }) { _, _ in }
        var opened = Set<String>()
        var shown = true
        let feed = SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { shown }),
                                       hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { _ in }, toggleShown: {},
                                                    openedSessions: { opened }), chats: chats)
        #expect(feed.panel()?.entries.map(\.id) == ["personal"])
        #expect(chats.snapshot().lanes.count == 2, "visibility must not prune the underlying session or its marks")
        opened = ["child"]
        #expect(Set(feed.panel()?.entries.map(\.id) ?? []) == ["personal", "child"])
        opened = []
        #expect(feed.panel()?.entries.map(\.id) == ["personal"], "closing the tab hides its automatic row again")
        #expect(chats.togglePin("child"))
        #expect(Set(feed.panel()?.entries.map(\.id) ?? []) == ["personal", "child"], "explicit pins survive a closed tab")
        #expect(chats.togglePin("child"))
        shown = false
        #expect(feed.panel()?.entries.map(\.id) == ["personal"], "an unopened child must not light the Priority bell")
    }
}
