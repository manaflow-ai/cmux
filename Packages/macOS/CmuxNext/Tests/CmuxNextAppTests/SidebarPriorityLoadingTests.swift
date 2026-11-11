import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextSidebar
import Foundation
import Testing

/// ui-state-fixes M6: the Priority view said "No agent chats right now" before any chat list was
/// read (an acpmux watch not up yet). It says it is loading until a store delivered its page, then
/// "No agent chats right now" only when the list is truly empty.
@MainActor
struct SidebarPriorityLoadingTests {
    private func feed(_ store: AgentLaneStore) -> SidebarPriorityFeed {
        let chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false }) { _, _ in }
        return SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }),
                                   hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { _ in }, toggleShown: {}), chats: chats)
    }

    @Test func anEmptyListIsLoadingUntilAStoreDeliveredItsPage() throws {
        let store = AgentLaneStore()
        let feed = feed(store)
        let before = try #require(feed.panel())
        #expect(before.entries.isEmpty)
        #expect(!before.loaded, "an unread chat list counted as no chats")
        store.live = true
        #expect(try #require(feed.panel()).loaded)
    }

    @Test func thePanelSaysLoadingBeforeTheListAndEmptyAfter() {
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        view.show(SidebarPriorityPanel(entries: [], loaded: false))
        #expect(view.emptyNote == Strings.priorityLoading, "the panel said No agent chats right now before its data arrived")
        view.show(SidebarPriorityPanel(entries: [], loaded: true))
        #expect(view.emptyNote == Strings.priorityEmpty)
    }
}
