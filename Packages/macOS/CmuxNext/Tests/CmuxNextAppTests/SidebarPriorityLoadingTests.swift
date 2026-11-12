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
    private func feed(_ store: AgentLaneStore, clock: ManualClock = ManualClock(),
                      retryLoad: @escaping @MainActor () -> Void = {}) -> SidebarPriorityFeed {
        let chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false }) { _, _ in }
        return SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }),
                                   hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { _ in }, toggleShown: {},
                                                retryLoad: retryLoad),
                                   chats: chats, clock: clock)
    }

    /// Waits for the next change of the panel after `body` runs.
    private func panelChange(_ feed: SidebarPriorityFeed, after body: () -> Void) async {
        let (changes, change) = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = feed.panel() } onChange: { change.yield() }
        body()
        for await _ in changes { break }
    }

    /// Round 4 (verifier M6): "Couldn't load agent chats." was a dead end, with no Retry. The panel
    /// now shows Try Again beside it; the view's own Try Again asks the watches to connect again,
    /// shows loading again and re-arms the deadline, which ends in the error again if nothing comes.
    @Test func couldntLoadOffersTryAgainThatReadsAgainUnderAFreshDeadline() async throws {
        let clock = ManualClock()
        let store = AgentLaneStore()
        let retries = RetryCount()
        let feed = feed(store, clock: clock) { retries.value += 1 }
        _ = feed.panel()
        try await clock.waitForSleeper()
        await panelChange(feed) { clock.advance(by: SidebarPriorityFeed.loadDeadline) }
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        view.onAction = { feed.perform($0) }
        view.show(try #require(feed.panel()))
        #expect(view.emptyNote == Strings.priorityLoadFailed)
        #expect(view.offersRetry, "Couldn't load agent chats. offered no Try Again")

        await panelChange(feed) { view.retry.performClick(nil) }
        #expect(retries.value == 1, "Try Again did not ask the chat lists' watches to read again")
        let again = try #require(feed.panel())
        #expect(!again.loaded && !again.loadFailed, "Try Again kept the error instead of loading again")
        view.show(again)
        #expect(view.emptyNote == Strings.priorityLoading)
        #expect(!view.offersRetry)
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1, "Try Again did not re-arm the deadline")

        await panelChange(feed) { clock.advance(by: SidebarPriorityFeed.loadDeadline) }
        let failedAgain = try #require(feed.panel())
        #expect(failedAgain.loadFailed, "the re-armed deadline never ended in the error")
        view.show(failedAgain)
        #expect(view.offersRetry)

        store.live = true
        view.show(try #require(feed.panel()))
        #expect(view.emptyNote == Strings.priorityEmpty)
        #expect(!view.offersRetry)
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

    /// Round 8 (verifier M6, blocking 4): the captures drew injected panels, so Try Again changed
    /// nothing they showed. The capture hold (`SidebarPriorityDebugHold`, `debug.sidebar_priority_hold`)
    /// drives the real feed instead: a held list read is loading, its own deadline ends it in the
    /// error, the panel's own Try Again runs the feed's retry and shows loading under a fresh
    /// deadline, and the release shows the real list.
    @Test func theCaptureHoldDrivesTheRealFeedThroughFailedRetryAndTheList() async throws {
        let clock = ManualClock()
        let store = AgentLaneStore()
        store.live = true
        let retries = RetryCount()
        let feed = feed(store, clock: clock) { retries.value += 1 }
        let hold = SidebarPriorityDebugHold()
        feed.debugHold = hold
        #expect(try #require(feed.panel()).loaded, "a live store read as not listed before the hold")

        hold.held = true
        let held = try #require(feed.panel())
        #expect(!held.loaded && !held.loadFailed, "a held list read did not show loading")
        #expect(SidebarPriorityDebugHold.state(of: held) == "loading")
        try await clock.waitForSleeper()
        await panelChange(feed) { clock.advance(by: SidebarPriorityFeed.loadDeadline) }
        let failed = try #require(feed.panel())
        #expect(SidebarPriorityDebugHold.state(of: failed) == "failed", "the held read never ended in the error")

        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        view.onAction = { feed.perform($0) }
        view.show(failed)
        #expect(view.offersRetry)
        await panelChange(feed) { view.retry.performClick(nil) }
        #expect(retries.value == 1, "the panel's Try Again did not run the feed's retry")
        let again = try #require(feed.panel())
        #expect(SidebarPriorityDebugHold.state(of: again) == "loading", "Try Again kept the error")
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1, "Try Again did not re-arm the deadline")

        hold.held = false
        let released = try #require(feed.panel())
        #expect(SidebarPriorityDebugHold.state(of: released) == "empty", "the release did not show the real (empty) list")
        #expect(!released.loadFailed)
        #expect(clock.sleeperCount == 0, "the listed panel left the deadline armed")
    }

    @Test func thePanelSaysLoadingBeforeTheListAndEmptyAfter() {
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        view.show(SidebarPriorityPanel(entries: [], loaded: false))
        #expect(view.emptyNote == Strings.priorityLoading, "the panel said No agent chats right now before its data arrived")
        view.show(SidebarPriorityPanel(entries: [], loaded: true))
        #expect(view.emptyNote == Strings.priorityEmpty)
    }
}

/// Counts the feed's retry hook calls.
@MainActor private final class RetryCount {
    var value = 0
}
