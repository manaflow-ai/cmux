import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextSidebar
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// ui-state-fixes M6: the Priority view said "No agent chats right now" before any chat list was
/// read (an acpmux watch not up yet). It says it is loading until a store delivered its page, then
/// "No agent chats right now" only when the list is truly empty.
@MainActor
struct SidebarPriorityLoadingTests {
    private func feed(_ store: AgentLaneStore, clock: ManualClock = ManualClock()) -> SidebarPriorityFeed {
        let chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false }) { _, _ in }
        return SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }),
                                   hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { _ in }, toggleShown: {}), chats: chats,
                                   clock: clock)
    }

    /// Round 2 (verifier M-2): with no acpmux daemon no store ever goes live, and the panel said
    /// "Loading agent chats…" forever. Past its deadline it says it couldn't load the chats; a
    /// list that arrives later replaces that.
    @Test func loadingEndsInCouldntLoadPastItsDeadlineAndALaterListReplacesIt() async throws {
        let clock = ManualClock()
        let store = AgentLaneStore()
        let feed = feed(store, clock: clock)
        let before = try #require(feed.panel())
        #expect(!before.loaded && !before.loadFailed)
        try await clock.waitForSleeper()
        let (changes, change) = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = feed.panel() } onChange: { change.yield() }
        clock.advance(by: SidebarPriorityFeed.loadDeadline)
        for await _ in changes { break }
        let failed = try #require(feed.panel())
        #expect(!failed.loaded && failed.loadFailed, "no chat list for the whole deadline still said loading")
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        view.show(failed)
        #expect(view.emptyNote == Strings.priorityLoadFailed)
        store.live = true
        let listed = try #require(feed.panel())
        #expect(listed.loaded && !listed.loadFailed, "a list read after the deadline still said couldn't load")
        view.show(listed)
        #expect(view.emptyNote == Strings.priorityEmpty)
    }

    @Test func aListReadBeforeTheDeadlineEndsIt() async throws {
        let clock = ManualClock()
        let store = AgentLaneStore()
        let feed = feed(store, clock: clock)
        _ = feed.panel()
        try await clock.waitForSleeper()
        store.live = true
        #expect(try #require(feed.panel()).loaded)
        // The listed panel cancelled the pending deadline: nothing sleeps on the clock any more.
        #expect(clock.sleeperCount == 0)
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
