import CmuxNextCompat
import Observation
import Testing

/// SIDEBAR MISSES (cmux21, 120 Hz, 200 workspaces, Release 150d97817df9, xctrace): every Cmd-N and Cmd-Shift-W
/// re-read the key of all 200 workspaces for the New Tab page's places (NewTabPlacesFeed: one observation over every
/// workspace, pane and tab), and the store's list change first cancelled that observation's whole access list. Inside
/// the missed refreshes of each insert that was 2 ms of the feed, a large share of the 4-10 ms of
/// `ObservationTracking.cancel` in the key's turn, and the re-tracking (`generateAccessList`) in the gaps after it.
/// The work of one change must not grow with the list: a list change reads the new model only, and a model's change
/// reads that model only.
@MainActor
@Suite struct ObservedItemsFeedTests {
    @MainActor @Observable final class Place {
        let id: String
        var title: String
        init(_ id: String) {
            self.id = id
            title = id
        }
    }

    @MainActor @Observable final class Places {
        var list: [Place]
        var open = true
        init(_ count: Int) { list = (0..<count).map { Place("w\($0)") } }
    }

    @MainActor final class Counts {
        var reads = 0
        var changes = 0
    }

    private func feed(_ places: Places, _ counts: Counts) -> ObservedItemsFeed<Place, String> {
        ObservedItemsFeed(list: { places.open ? places.list : nil }, id: { $0.id },
                          item: { place in
                              counts.reads += 1
                              return place.title
                          },
                          changed: { counts.changes += 1 })
    }

    /// Yields until `done` holds (bounded): the feed's observations run on later main-actor turns.
    private func settle(turns: Int = 2_000, _ done: () -> Bool) async {
        for _ in 0..<turns where !done() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func aChangeReadsOnlyWhatChangedWhateverTheListLength() async {
        let places = Places(200)
        let counts = Counts()
        let feed = feed(places, counts)
        feed.start()
        defer { feed.stop() }
        await settle { counts.reads >= 200 }
        #expect(counts.reads == 200)

        counts.reads = 0
        let seventh = places.list[7]
        seventh.title = "renamed"
        await settle { counts.changes == 1 }
        #expect(counts.changes == 1)
        #expect(counts.reads <= 2, "one model's change re-read \(counts.reads) of 200 items")

        counts.reads = 0
        places.list.append(Place("w200"))
        await settle { counts.changes == 2 }
        #expect(counts.changes == 2)
        #expect(counts.reads <= 2, "a list insert re-read \(counts.reads) of 201 items")

        counts.reads = 0
        places.list.remove(at: 3)
        await settle { counts.changes == 3 }
        #expect(counts.changes == 3)
        #expect(counts.reads <= 2, "a list remove re-read \(counts.reads) of 200 items")
    }

    @Test func theFirstItemsAfterNoListAreTheBaseline() async {
        let places = Places(3)
        places.open = false
        let counts = Counts()
        let feed = feed(places, counts)
        feed.start()
        defer { feed.stop() }
        places.open = true
        await settle { counts.reads >= 3 }
        let first = places.list[0]
        first.title = "renamed"
        await settle { counts.changes == 1 }
        #expect(counts.changes == 1, "opening counted as a change, or the rename did not")

        places.open = false
        await settle(turns: 30) { false } // no signal for a closed list: give its stream turns to see it
        let second = places.list[1]
        second.title = "renamed while closed"
        places.open = true
        await settle { counts.reads >= 6 }
        let third = places.list[2]
        third.title = "renamed"
        await settle { counts.changes == 2 }
        #expect(counts.changes == 2, "a reopen counted as a change, or a rename after it did not")
    }
}
