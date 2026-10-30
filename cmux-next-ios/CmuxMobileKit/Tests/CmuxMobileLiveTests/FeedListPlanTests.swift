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

    /// Only events never shown before count for the "N new" pill (an undone Done does not).
    @Test func onlyNeverSeenEventsAreNew() {
        var seen: Set<String> = ["a", "b"]
        #expect(FeedListPlan.fresh(["n1", "a"], seen: &seen) == ["n1"])
        #expect(FeedListPlan.fresh(["n1"], seen: &seen).isEmpty)
    }
}
