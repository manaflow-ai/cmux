import Foundation
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("RecoverableWindowRouteLedger")
struct RecoverableWindowRouteLedgerTests {
    private func makeId() -> WindowID { WindowID(UUID()) }

    private func remember(
        _ ledger: RecoverableWindowRouteLedger<String>,
        _ value: String,
        for id: WindowID
    ) {
        ledger.setRoute(value, order: ledger.issueOrder(), for: id)
    }

    @Test("setRoute/route round-trips per window and reports membership/count")
    func setAndGet() {
        let ledger = RecoverableWindowRouteLedger<String>()
        let a = makeId()
        let b = makeId()
        remember(ledger, "alpha", for: a)
        remember(ledger, "beta", for: b)
        #expect(ledger.route(for: a) == "alpha")
        #expect(ledger.route(for: b) == "beta")
        #expect(ledger.contains(a))
        #expect(ledger.contains(makeId()) == false)
        #expect(ledger.count == 2)
        #expect(Set(ledger.routes) == ["alpha", "beta"])
    }

    @Test("setRoute replaces a prior route for the same window")
    func setReplaces() {
        let ledger = RecoverableWindowRouteLedger<String>()
        let a = makeId()
        remember(ledger, "first", for: a)
        remember(ledger, "second", for: a)
        #expect(ledger.route(for: a) == "second")
        #expect(ledger.count == 1)
    }

    @Test("remove drops and returns only that window's route, idempotently")
    func explicitRemove() {
        let ledger = RecoverableWindowRouteLedger<String>()
        let a = makeId()
        let b = makeId()
        remember(ledger, "alpha", for: a)
        remember(ledger, "beta", for: b)

        #expect(ledger.remove(a) == "alpha")
        #expect(ledger.route(for: a) == nil)
        #expect(ledger.contains(a) == false)
        #expect(ledger.route(for: b) == "beta")
        #expect(ledger.remove(a) == nil)
    }

    @Test("issueOrder is monotonic so the most-recently-remembered route sorts first")
    func sortByOrderDescending() {
        let ledger = RecoverableWindowRouteLedger<String>()
        let first = makeId()
        let second = makeId()
        let third = makeId()
        remember(ledger, "first", for: first)
        remember(ledger, "second", for: second)
        remember(ledger, "third", for: third)
        #expect(ledger.sortedByMostRecentFirst() == ["third", "second", "first"])
    }

    @Test("re-remembering a window advances its order to the front")
    func reRememberAdvancesOrder() {
        let ledger = RecoverableWindowRouteLedger<String>()
        let a = makeId()
        let b = makeId()
        remember(ledger, "a", for: a)
        remember(ledger, "b", for: b)
        // a was remembered first; re-remembering it issues a newer order.
        remember(ledger, "a", for: a)
        #expect(ledger.sortedByMostRecentFirst() == ["a", "b"])
    }

    @Test("equal-order tie breaks by ascending WindowID UUID string")
    func tieBreakByUuidString() {
        let ledger = RecoverableWindowRouteLedger<String>()
        // Two ids whose UUID strings have a known relative order.
        let lower = WindowID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let higher = WindowID(UUID(uuidString: "FF000000-0000-0000-0000-000000000000")!)
        // Force identical order by stamping both at the same value.
        ledger.setRoute("higher", order: 5, for: higher)
        ledger.setRoute("lower", order: 5, for: lower)
        // Same order: ascending UUID string wins, so "lower" comes first.
        #expect(ledger.sortedByMostRecentFirst() == ["lower", "higher"])
    }

    @Test("retainRoutes keeps only matching windows and exposes id+value")
    func retainRoutesFilters() {
        let ledger = RecoverableWindowRouteLedger<String>()
        let keep = makeId()
        let drop = makeId()
        remember(ledger, "keep", for: keep)
        remember(ledger, "drop", for: drop)

        var seen: Set<WindowID> = []
        ledger.retainRoutes { id, value in
            seen.insert(id)
            return value == "keep"
        }
        #expect(seen == [keep, drop])
        #expect(ledger.contains(keep))
        #expect(ledger.contains(drop) == false)
        #expect(ledger.count == 1)
    }

    @Test("pairs surfaces each window id alongside its route value")
    func pairsRoundTrip() {
        let ledger = RecoverableWindowRouteLedger<String>()
        let a = makeId()
        let b = makeId()
        remember(ledger, "alpha", for: a)
        remember(ledger, "beta", for: b)
        let map = Dictionary(uniqueKeysWithValues: ledger.pairs.map { ($0.id, $0.route) })
        #expect(map[a] == "alpha")
        #expect(map[b] == "beta")
    }
}
