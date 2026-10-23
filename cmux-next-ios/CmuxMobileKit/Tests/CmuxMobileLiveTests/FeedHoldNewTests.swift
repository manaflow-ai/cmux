import CmuxMobileFeed
import Foundation
import Observation
import Testing

/// While the person reads below the top of the Feed, a new event must not go
/// into the list above them: the list would shift every row under their
/// finger and re-lay out each one (verify/feed-perf-20261021.md). It waits
/// behind the "N new" pill, still counted for the badge and saved, and joins
/// the list at the top when they go back up or tap the pill.
@MainActor
@Suite struct FeedHoldNewTests {
    static func item(_ id: String, ago: TimeInterval = 0, kind: FeedItem.Kind = .finished) -> FeedItem {
        FeedItem(id: id, kind: kind, workspaceID: "w1", tabID: "t", agentName: "Codex", harness: "codex",
                 workspaceTitle: "cmux", markdown: "body \(id)", quote: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - ago))
    }

    final class Count: @unchecked Sendable { var value = 0 }

    func visibleNotifications(_ store: FeedStore, _ change: () -> Void) -> Int {
        let count = Count()
        withObservationTracking { _ = store.visibleItems } onChange: { count.value += 1 }
        change()
        return count.value
    }

    @Test func newEventWaitsWhileReadingBelowTheTop() {
        let store = FeedStore(items: [Self.item("a", ago: 10), Self.item("b", ago: 20)])
        store.isReadingBelowTop = true
        let notified = visibleNotifications(store) {
            store.upsert(Self.item("new", kind: .needsInput), atTop: true)
        }
        #expect(notified == 0)
        #expect(store.visibleItems.map(\.id) == ["a", "b"])
        #expect(store.unseenNewIDs == ["new"])
        // Counted and kept even before it shows.
        #expect(store.items.map(\.id).contains("new"))
        #expect(store.needsYouCount == 1)
    }

    @Test func heldEventsJoinAtTheTopWhenTheReaderGoesBackUp() {
        let store = FeedStore(items: [Self.item("a", ago: 10)])
        store.isReadingBelowTop = true
        store.upsert(Self.item("n1", ago: 2), atTop: true)
        store.upsert(Self.item("n2", ago: 1), atTop: true)
        #expect(store.visibleItems.map(\.id) == ["a"])
        store.isReadingBelowTop = false
        #expect(store.visibleItems.map(\.id) == ["n2", "n1", "a"])
        #expect(store.unseenNewIDs.isEmpty)
    }

    @Test func tappingThePillShowsThemToo() {
        let store = FeedStore(items: [Self.item("a", ago: 10)])
        store.isReadingBelowTop = true
        store.upsert(Self.item("n1"), atTop: true)
        store.clearUnseen()
        #expect(store.visibleItems.map(\.id) == ["n1", "a"])
    }

    @Test func changesToShownEventsStillApplyWhileReading() {
        let store = FeedStore(items: [Self.item("a", ago: 10)])
        store.isReadingBelowTop = true
        store.markRead("a")
        #expect(store.visibleItems.first?.isRead == true)
        var changed = Self.item("a", ago: 10)
        changed.markdown = "new text"
        store.upsert(changed, atTop: true)
        #expect(store.visibleItems.first?.markdown == "new text")
        #expect(store.unseenNewIDs.isEmpty)
    }

    @Test func atTheTopNewEventsShowAtOnce() {
        let store = FeedStore(items: [Self.item("a", ago: 10)])
        store.upsert(Self.item("n1"), atTop: true)
        #expect(store.visibleItems.map(\.id) == ["n1", "a"])
        #expect(store.unseenNewIDs.isEmpty)
    }

    @Test func aWithdrawnHeldEventLeavesThePill() {
        let store = FeedStore(items: [Self.item("a", ago: 10)])
        store.isReadingBelowTop = true
        store.upsert(Self.item("n1"), atTop: true)
        store.remove("n1")
        #expect(store.unseenNewIDs.isEmpty)
        store.isReadingBelowTop = false
        #expect(store.visibleItems.map(\.id) == ["a"])
    }

    /// An event added while the Feed shows its top was seen there: scrolling down never hides it.
    @Test func anEventSeenAtTheTopIsNotHiddenLater() {
        let store = FeedStore(items: [Self.item("a", ago: 10)])
        store.upsert(Self.item("n1"), atTop: false)
        #expect(store.visibleItems.map(\.id) == ["n1", "a"])
        store.isReadingBelowTop = true
        #expect(store.visibleItems.map(\.id) == ["n1", "a"])
        #expect(store.unseenNewIDs.isEmpty)
    }

    /// The pill counts only held events the list would show.
    @Test func thePillCountsOnlyWhatTheListWouldShow() {
        let store = FeedStore(items: [Self.item("a", ago: 10)])
        store.isReadingBelowTop = true
        store.upsert(Self.item("ask", ago: 2, kind: .needsInput), atTop: true)
        store.upsert(Self.item("done", ago: 1), atTop: true)
        #expect(store.unseenVisibleCount == 2)
        store.filter = .needsYou
        #expect(store.unseenVisibleCount == 1)
        store.filter = .all
        store.markDone("done")
        #expect(store.unseenVisibleCount == 1)
    }
}
