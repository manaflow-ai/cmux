@testable import CmuxMobileFeed
import Foundation
import Testing

/// The Feed list's UIKit rewrite (verify/feed-perf-20261022.md): a row's
/// layout is computed once per (event, row state, width, text size) and a
/// store change reconfigures only the rows whose event changed.
@MainActor
@Suite struct FeedListPlanTests {
    static func item(_ id: String, _ markdown: String = "body", ago: TimeInterval = 0) -> FeedItem {
        FeedItem(id: id, kind: .finished, workspaceID: "w1", tabID: "t", agentName: "Codex", harness: "codex",
                 workspaceTitle: "cmux", markdown: markdown, quote: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - ago))
    }

    static func key(_ item: FeedItem, state: FeedRowState = FeedRowState(), width: Int = 360) -> FeedRowKey {
        FeedRowKey(item: item, state: state, width: width, textSize: "L")
    }

    // MARK: Layout cache

    @Test func aRowIsLaidOutOncePerEventAndWidth() {
        let cache = FeedRowLayoutCache<Int>()
        let a = Self.item("a")
        var computed = 0
        let compute: () -> Int = { computed += 1; return 100 }
        #expect(cache.value(for: Self.key(a), compute: compute) == 100)
        #expect(cache.value(for: Self.key(a), compute: compute) == 100)
        #expect(computed == 1)
        // The event changes: only its row is laid out again.
        var changed = a
        changed.markdown = "new body"
        _ = cache.value(for: Self.key(changed), compute: compute)
        #expect(computed == 2)
        // A row state change (Show more) or a new width also lays it out again.
        _ = cache.value(for: Self.key(changed, state: FeedRowState(expanded: true)), compute: compute)
        _ = cache.value(for: Self.key(changed, state: FeedRowState(expanded: true), width: 400), compute: compute)
        #expect(computed == 4)
    }

    @Test func otherRowsKeepTheirLayout() {
        let cache = FeedRowLayoutCache<Int>()
        let items = (0..<50).map { Self.item("i\($0)", ago: Double($0)) }
        for item in items { cache.store(1, for: Self.key(item)) }
        var read = items[10]
        read.isRead.toggle()
        cache.store(2, for: Self.key(read))
        #expect(items.enumerated().filter { $0.offset != 10 }.allSatisfy { cache.cached(Self.key($0.element)) == 1 })
        #expect(cache.cached(Self.key(items[10])) == nil)
        #expect(cache.cached(Self.key(read)) == 2)
    }

    @Test func goneRowsArePruned() {
        let cache = FeedRowLayoutCache<Int>()
        cache.store(1, for: Self.key(Self.item("a")))
        cache.store(1, for: Self.key(Self.item("b")))
        cache.prune(keeping: ["b"])
        #expect(cache.count == 1)
        #expect(cache.cached(Self.key(Self.item("b"))) == 1)
    }

    // MARK: Snapshot plan

    @Test func aChangedEventReconfiguresItsRowOnly() {
        let old = (0..<5).map { Self.item("i\($0)", ago: Double($0)) }
        var new = old
        new[2].markdown = "edited"
        let plan = FeedListPlan(old: old.map { ($0.id, Self.key($0)) }, new: new.map { ($0.id, Self.key($0)) }, anchorID: nil)
        #expect(!plan.orderChanged)
        #expect(plan.reconfigure == ["i2"])
        #expect(plan.inserted.isEmpty)
    }

    @Test func theSameEventsAgainChangeNothing() {
        let old = (0..<5).map { Self.item("i\($0)", ago: Double($0)) }
        let plan = FeedListPlan(old: old.map { ($0.id, Self.key($0)) }, new: old.map { ($0.id, Self.key($0)) }, anchorID: "i3")
        #expect(plan.isEmpty)
    }

    @Test func eventsArrivingAboveTheReaderAreCountedForThePill() {
        let old = (0..<5).map { Self.item("i\($0)", ago: Double($0 + 2)) }
        let new = [Self.item("n1", ago: 0), Self.item("n0", ago: 1)] + old + [Self.item("late", ago: 99)]
        let plan = FeedListPlan(old: old.map { ($0.id, Self.key($0)) }, new: new.map { ($0.id, Self.key($0)) }, anchorID: "i3")
        #expect(plan.orderChanged)
        #expect(plan.inserted == ["n1", "n0", "late"])
        #expect(plan.insertedAbove(anchor: "i3", in: new.map(\.id)) == 2)
        #expect(plan.reconfigure.isEmpty)
    }

    // MARK: Snapshot edits

    @Test func aLiveInsertIsAnEditNotARebuild() {
        let edit = FeedSnapshotEdit(old: ["a", "b", "c"], new: ["n1", "n2", "a", "b", "x", "c", "z"])
        #expect(edit == FeedSnapshotEdit.init(old: ["a", "b", "c"], new: ["n1", "n2", "a", "b", "x", "c", "z"]))
        #expect(edit?.removed == [])
        #expect(edit?.groups == [.init(before: "a", ids: ["n1", "n2"]), .init(before: "c", ids: ["x"])])
        #expect(edit?.tail == ["z"])
    }

    @Test func aRemovalIsAnEdit() {
        let edit = FeedSnapshotEdit(old: ["a", "b", "c"], new: ["a", "c"])
        #expect(edit?.removed == ["b"])
        #expect(edit?.groups == [])
        #expect(edit?.tail == [])
    }

    @Test func aReSortRebuilds() {
        #expect(FeedSnapshotEdit(old: ["a", "b", "c"], new: ["b", "a", "c"]) == nil)
    }

    // MARK: The pinned group (open asks first)

    static func ask(_ id: String, ago: TimeInterval) -> FeedItem {
        FeedItem(id: id, kind: .needsInput, workspaceID: "w1", tabID: "t", agentName: "Claude", harness: "claude",
                 workspaceTitle: "cmux", markdown: "body", quote: nil, createdAt: Date(timeIntervalSince1970: 1_000_000 - ago))
    }

    /// The whole Feed's first rows are its open asks; a filtered Feed has no pinned group.
    @Test func thePinnedGroupIsTheOpenAsksOfTheWholeFeed() {
        let store = FeedStore(items: [Self.item("new", ago: 1), Self.ask("ask-old", ago: 30), Self.item("mid", ago: 10), Self.ask("ask-new", ago: 5)])
        #expect(store.visibleItems.map(\.id) == ["ask-new", "ask-old", "new", "mid"])
        #expect(FeedPinnedGroup.count(store.visibleItems, filter: .all) == 2)
        #expect(FeedPinnedGroup.title(2) == "Needs you · 2")
        store.filter = .needsYou
        #expect(store.visibleItems.map(\.id) == ["ask-new", "ask-old"])
        #expect(FeedPinnedGroup.count(store.visibleItems, filter: store.filter) == 0)
        store.filter = .finished
        #expect(FeedPinnedGroup.count(store.visibleItems, filter: store.filter) == 0)
        // Answered: the ask is an event in time order again, and the group is one smaller.
        store.filter = .all
        store.resolveElsewhere("ask-old", text: "Answered")
        #expect(store.visibleItems.map(\.id) == ["ask-new", "new", "mid", "ask-old"])
        #expect(FeedPinnedGroup.count(store.visibleItems, filter: .all) == 1)
        store.resolveElsewhere("ask-new", text: "Answered")
        #expect(store.visibleItems.map(\.id) == ["new", "ask-new", "mid", "ask-old"])
        #expect(FeedPinnedGroup.count(store.visibleItems, filter: .all) == 0)
    }

    /// An answered ask leaves the pinned group as one row move (the table animates it), not a rebuild.
    @Test func anAnsweredAskIsARowMove() {
        let old = ["ask-new", "ask-old", "new", "mid", "last"]
        let new = ["ask-new", "new", "mid", "ask-old", "last"]
        #expect(FeedSnapshotEdit(old: old, new: new) == nil)
        let move = FeedMoveEdit(old: old, new: new, movers: ["ask-old"])
        #expect(move?.removed == [])
        #expect(move?.steps == [.move("ask-old", before: "last")])
        #expect(move?.applied(to: old) == new)
        // The oldest event of all: it goes after the last row.
        let toEnd = FeedMoveEdit(old: ["ask", "a", "b"], new: ["a", "b", "ask"], movers: ["ask"])
        #expect(toEnd?.steps == [.move("ask", before: nil)])
        #expect(toEnd?.applied(to: ["ask", "a", "b"]) == ["a", "b", "ask"])
        // An ask that opens again goes back up.
        let back = FeedMoveEdit(old: ["a", "b", "ask"], new: ["ask", "a", "b"], movers: ["ask"])
        #expect(back?.applied(to: ["a", "b", "ask"]) == ["ask", "a", "b"])
    }

    /// A live event and a removal in the same update ride along with the move.
    @Test func aMoveCarriesInsertsAndRemovals() {
        let old = ["ask-1", "ask-2", "a", "b", "c"]
        let new = ["ask-2", "n1", "a", "ask-1", "c", "n2"]
        let move = FeedMoveEdit(old: old, new: new, movers: ["ask-1"])
        #expect(move?.removed == ["b"])
        #expect(move?.steps == [.insert("n2", before: nil), .move("ask-1", before: "c"), .insert("n1", before: "a")])
        #expect(move?.applied(to: old) == new)
        // Two asks answered at once.
        let both = FeedMoveEdit(old: old, new: ["a", "ask-1", "b", "c", "ask-2"], movers: ["ask-1", "ask-2"])
        #expect(both?.applied(to: old) == ["a", "ask-1", "b", "c", "ask-2"])
    }

    /// Any other row changing place, no mover, or too many at once: the section is rebuilt as before.
    @Test func otherReordersStillRebuild() {
        #expect(FeedMoveEdit(old: ["ask", "a", "b"], new: ["b", "a", "ask"], movers: ["ask"]) == nil)
        #expect(FeedMoveEdit(old: ["a", "b"], new: ["b", "a"], movers: []) == nil)
        #expect(FeedMoveEdit(old: ["a", "b"], new: ["b", "a"], movers: ["gone"]) == nil)
        let asks = (0..<5).map { "ask\($0)" }
        #expect(FeedMoveEdit(old: asks + ["a"], new: ["a"] + asks, movers: Set(asks), limit: 4) == nil)
        #expect(FeedMoveEdit(old: asks + ["a"], new: ["a"] + asks, movers: Set(asks), limit: 5)?.applied(to: asks + ["a"]) == ["a"] + asks)
    }

    /// Only events never shown before count for the "N new" pill (an undone Done does not).
    @Test func onlyNeverSeenEventsAreNew() {
        var seen: Set<String> = ["a", "b"]
        #expect(FeedListPlan.fresh(["n1", "a"], seen: &seen) == ["n1"])
        #expect(FeedListPlan.fresh(["n1"], seen: &seen).isEmpty)
    }
}
