import CmuxNextCompat
import Observation
import Testing

/// `ObservedItems` hands its owner the ONE changed item, with its place in the items handed out last, so an owner
/// that joins a session-sized list updates its join with no pass over the list (OBSERVATION 800: at 826 workspaces
/// each joined reader asked for every item again after one change).
@MainActor
@Suite struct ObservedItemsChangeTests {
    @MainActor @Observable final class Place {
        let id: String
        var title: String?
        init(_ id: String, title: String?) {
            self.id = id
            self.title = title
        }
    }

    @MainActor final class Seen {
        var changes: [(position: Int, old: String, new: String)] = []
    }

    /// Yields until `done` holds (bounded): the observations run on later main-actor turns.
    private func settle(turns: Int = 2_000, _ done: () -> Bool) async {
        for _ in 0..<turns where !done() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// The place of a change is the item's index in the items handed out, also when an earlier model has no item and
    /// after the list moved.
    @Test func aChangeNamesItsPlaceInTheItemsHandedOut() async {
        let places = [Place("a", title: "A"), Place("b", title: nil), Place("c", title: "C"), Place("d", title: "D")]
        let seen = Seen()
        let work = ObservationWork()
        let observed = ObservationWork.$current.withValue(work) {
            ObservedItems<Place, String>(item: { $0.title }, same: { $0 == $1 },
                                         changedItem: { seen.changes.append(($0.position, $0.old, $0.new)) })
        }
        defer { observed.cancelAll() }
        let first = ObservationWork.$current.withValue(work) { observed.items(for: places, id: { $0.id }) }
        #expect(first == ["A", "C", "D"])
        #expect(work.byStep["ObservedItems.list"] == 4)

        // One model's change: the owner gets that item and its place; the list is not visited again.
        work.reset()
        places[2].title = "C2"
        await settle { seen.changes.count == 1 }
        #expect(seen.changes.map(\.position) == [1])
        #expect(seen.changes.last?.old == "C" && seen.changes.last?.new == "C2")
        #expect(work.byStep["ObservedItems.list"] == nil)

        // The list moved: a kept model's place follows the new order.
        let moved = ObservationWork.$current.withValue(work) { observed.items(for: [places[3], places[2], places[0]], id: { $0.id }) }
        #expect(moved == ["D", "C2", "A"])
        places[0].title = "A2"
        await settle { seen.changes.count == 2 }
        #expect(seen.changes.last?.position == 2)
        #expect(seen.changes.last?.old == "A" && seen.changes.last?.new == "A2")
    }

    @Test func sortedPositionsKeepTheFirstHolder() {
        var holders = SortedPositions()
        #expect(holders.first == nil && holders.isEmpty)
        for position in [7, 2, 9, 2, 4] { holders.insert(position) }
        #expect(holders.positions == [2, 4, 7, 9])
        holders.remove(2)
        holders.remove(5)
        #expect(holders.first == 4 && holders.count == 3)
        holders.remove(4)
        holders.remove(9)
        holders.remove(7)
        #expect(holders.isEmpty)
    }
}
