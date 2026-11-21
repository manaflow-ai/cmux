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

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private func drain() async {
        for _ in 0..<160 { await Task.yield() }
    }

    /// SplitMix64 as a plain value: the same seed gives the same steps.
    struct Seed {
        var state: UInt64

        /// The next number in `0..<bound`.
        mutating func next(below bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }

    /// One model's change visits no other model of the list, whatever the length of the list: the feed puts the one
    /// changed item in its place in the items that it handed out last. The base's row above counts the maps of the
    /// item (`reads`); a pass over the list maps no model again, so that count does not see it. This count is the
    /// module's own work counter (``ObservationWork``), which the test sets around the feed's start.
    ///
    /// The sign that the feed ran is a condition of the setup: the feed's items have the changed item.
    @Test func aChangeOfOneItemVisitsNoOtherModelOfTheList() async throws {
        let places = Places(826)
        let counts = Counts()
        let work = ObservationWork()
        let feed = feed(places, counts)
        ObservationWork.$current.withValue(work) { feed.start() }
        defer { feed.stop() }
        await drain()
        let first = feed.observedItems?.count ?? -1
        try #require(first == 826, "setup: the feed has \(first) items after the drain, want 826")

        work.reset()
        let changed = places.list[400]
        changed.title = "renamed"
        await drain()
        try #require(feed.observedItems?[400] == "renamed", "setup: the feed does not have the changed item after the drain")
        let listed = work.byStep["ObservedItems.list"] ?? 0
        let mapped = work.byStep["ObservedItems.map"] ?? 0
        print("observed items feed, 826 models: the change of one item visited \(listed) models in passes over the list and mapped \(mapped)")
        #expect(listed == 0, "the change of one item visited \(listed) models of 826 in passes over the list, want 0")
        #expect(mapped == 1, "the change of one item mapped \(mapped) models, want the changed one only")
        #expect(counts.changes == 1, "the change of one item ran the feed's `changed` \(counts.changes) times, want 1")
        #expect(feed.observedItems == places.list.map(\.title), "the feed's items are not the map of the list after the change of one item")
    }

    /// The copy of the items that an owner keeps from the feed's `update`.
    @MainActor final class Kept {
        var items: [String]?
    }

    @MainActor final class Heard {
        var values: [[String]?] = []
    }

    /// A reader that tracks the feed's items (``ObservedItemsFeed/observedItems``) hears the change of one item one
    /// time, with the changed item in its place, and hears the end of the list one time. An owner that reads the
    /// items so and takes no `changed` has no other signal of a change.
    ///
    /// The sign that the reader runs is a condition of the setup: the last items that it heard are the first ones.
    /// The change of the one item makes no pass over the list (the module's own work counter, set around the
    /// feed's start), so the reader hears the path that writes the item in its place.
    @Test func aTrackedReaderOfTheItemsHearsTheChangeOfOneItemOneTime() async throws {
        let places = Places(40)
        let counts = Counts()
        let work = ObservationWork()
        let feed = feed(places, counts)
        ObservationWork.$current.withValue(work) { feed.start() }
        defer { feed.stop() }
        let heard = Heard()
        let reading = Task {
            for await items in ObservationStream({ ObservationTrigger(feed.observedItems) }) {
                heard.values.append(items.value)
            }
        }
        defer { reading.cancel() }
        await drain()
        await drain()
        let first: [String]? = heard.values.last ?? nil
        try #require(first == places.list.map(\.title), "setup: the reader's last items are not the first ones: \(String(describing: first))")

        var before = heard.values.count
        work.reset()
        let changed = places.list[17]
        changed.title = "renamed"
        await drain()
        await drain()
        let afterChange = heard.values.count - before
        let renamed: [String]? = heard.values.last ?? nil
        let listed = work.byStep["ObservedItems.list"] ?? 0
        #expect(listed == 0, "the change of one item visited \(listed) models of 40 in passes over the list, want 0")
        #expect(afterChange == 1, "the reader heard \(afterChange) values after the change of one item, want 1")
        #expect(renamed == places.list.map(\.title), "the reader's last items do not have the changed item: \(String(describing: renamed))")

        before = heard.values.count
        places.open = false
        await drain()
        await drain()
        let afterEnd = heard.values.count - before
        let ended: [String]? = heard.values.last ?? nil
        #expect(afterEnd == 1, "the reader heard \(afterEnd) values after the end of the list, want 1")
        #expect(ended == nil, "the reader's last items after the end of the list are not nil: \(String(describing: ended))")
    }

    /// One thing that an owner of a feed got: every item, one item's change, or the call of `changed`.
    enum Got: Equatable {
        case items([String])
        case item(place: Int, old: String, new: String)
        case changed
    }

    @MainActor final class Taken {
        var got: [Got] = []
    }

    /// An owner that takes the feed's `update` gets every item at the first items, with no `changed`; the one
    /// item's place, the item before and the item now at the change of one item; every item again at a change of
    /// the list; each of the 2 before the feed's `changed`. It gets nothing at the end of the list, and every item
    /// again, with no `changed`, when a list comes again.
    ///
    /// This row has no red first: it holds what the feed gives to an owner that keeps the items in step.
    @Test func anOwnerThatTakesTheUpdateGetsEachChangeBeforeChangedAndNothingAtTheEndOfTheList() async throws {
        let places = Places(4)
        let taken = Taken()
        let feed = ObservedItemsFeed<Place, String>(
            list: { places.open ? places.list : nil }, id: { $0.id }, item: { $0.title },
            changed: { taken.got.append(.changed) },
            update: { update in
                switch update {
                case .items(let all): taken.got.append(.items(all))
                case .item(let change): taken.got.append(.item(place: change.position, old: change.old, new: change.new))
                }
            })
        feed.start()
        defer { feed.stop() }
        await drain()
        try #require(taken.got == [.items(["w0", "w1", "w2", "w3"])], "setup: the owner did not get the first items alone: \(taken.got)")

        taken.got = []
        let third = places.list[2]
        third.title = "renamed"
        await drain()
        #expect(taken.got == [.item(place: 2, old: "w2", new: "renamed"), .changed],
                "the owner did not get the one item's change, then `changed`: \(taken.got)")

        taken.got = []
        places.list.append(Place("w4"))
        await drain()
        #expect(taken.got == [.items(["w0", "w1", "renamed", "w3", "w4"]), .changed],
                "the owner did not get every item after a change of the list, then `changed`: \(taken.got)")

        taken.got = []
        places.open = false
        await drain()
        try #require(feed.observedItems == nil, "setup: the feed still has items after the end of the list")
        #expect(taken.got == [], "the owner got an update or a `changed` at the end of the list: \(taken.got)")

        places.open = true
        await drain()
        #expect(taken.got == [.items(["w0", "w1", "renamed", "w3", "w4"])],
                "the owner did not get the first items alone when a list came again: \(taken.got)")
    }

    /// A model that the list has at 2 places has its change at each of them, and at its one place after the list
    /// has it once again: the feed writes no item by its place while the list has one id at 2 places.
    ///
    /// This row has no red first: it holds what must stay when a change of one item makes no pass.
    @Test func aModelThatTheListHasTwiceHasItsChangeAtEachOfItsPlaces() async throws {
        let places = Places(5)
        let twice = places.list[1]
        places.list.append(twice)
        let counts = Counts()
        let feed = feed(places, counts)
        feed.start()
        defer { feed.stop() }
        await drain()
        try #require(feed.observedItems == ["w0", "w1", "w2", "w3", "w4", "w1"], "setup: the feed's first items are not the map of the list")

        twice.title = "renamed"
        await drain()
        #expect(feed.observedItems == ["w0", "renamed", "w2", "w3", "w4", "renamed"],
                "a model at 2 places of the list does not have its change at each of them: \(String(describing: feed.observedItems))")

        places.list.removeLast()
        await drain()
        twice.title = "once"
        await drain()
        #expect(feed.observedItems == ["w0", "once", "w2", "w3", "w4"],
                "a model at one place again does not have its change there: \(String(describing: feed.observedItems))")
    }

    /// The feed's items after each step of a run of steps from a seed: a change of one item, of 2 items in one turn,
    /// a model that comes, goes or moves, a change of one item in the turn of a change of the list (before or after
    /// it, so the item's change comes between the list's change and the feed's pass), a change of a model in the
    /// turn in which it leaves the list, a list that ends and comes again, and a second model under an id that the
    /// list has.
    ///
    /// The items are the map of the list after each step, with one exception that the feed has always had: of 2
    /// listed models under one id only the later one is observed, so a change of the earlier one alone shows at
    /// the next pass over the list. While the list has 2 models under one id, each change of an observed item
    /// makes that pass (the feed writes no item by its place then), so each model is mapped again.
    ///
    /// Each seed makes 2 runs. The first has the second model under one id, which stays in the list, so most of
    /// its changes of an item make a pass. The second has each id once (its kind 9 is a change of one item), more
    /// kinds that change items only, and a list that ended comes again in the next step: there a change of items
    /// only puts them in place with no pass. The row counts the steps of each path with the module's own work
    /// counter (``ObservationWork``), set around the feed's start, and prints them; with each id once, more than
    /// half of the steps put their items in place.
    ///
    /// The feed of each run gives its `update` to an owner that keeps a copy of the items (every item after a
    /// pass, the one item in its place at one item's change). After each step with a list the copy is the feed's
    /// items.
    ///
    /// This row has no red first: it holds what must stay when a change of one item makes no pass.
    @Test func theItemsFollowTheListThroughEachStepOfARunFromASeed() async throws {
        // The steps that put items in place with no pass, and the steps that made a pass, by the kind of run.
        var inPlaceOnce = 0
        var passedOnce = 0
        var inPlaceTwice = 0
        var passedTwice = 0
        for run in 0..<16 {
            let seed = run / 2 + 1
            // The second run of a seed: each id of the list has one place for the whole run.
            let once = run % 2 == 1
            var random = Seed(state: UInt64(seed))
            let places = Places(12)
            let work = ObservationWork()
            let kept = Kept()
            let feed = ObservedItemsFeed<Place, String>(
                list: { places.open ? places.list : nil }, id: { $0.id }, item: { $0.title },
                update: { update in
                    switch update {
                    case .items(let all): kept.items = all
                    case .item(let change): kept.items?[change.position] = change.new
                    }
                })
            ObservationWork.$current.withValue(work) { feed.start() }
            defer { feed.stop() }
            await drain()
            var made = 12
            var want: [String]? = places.list.map(\.title)
            for step in 0..<160 {
                var kind = random.next(below: once ? 24 : 12)
                // With each id once, kind 9 and each kind from 12 are a change of one item or of 2 items.
                if once, kind == 9 || kind >= 12 { kind %= 4 }
                let pick = places.list[random.next(below: places.list.count)]
                let other = places.list[random.next(below: places.list.count)]
                let title = "s\(seed)-\(step)"
                /// Whether the feed observes `place`: the later of 2 listed models under one id takes the observation.
                func observed(_ place: Place) -> Bool { places.list.last(where: { $0.id == place.id }) === place }
                // True when the step makes the feed pass over its list: the list changed, or an observed item did.
                var pass = observed(pick)
                // With each id once, a list that ended comes again here, in the turn of this step's change.
                if once, !places.open, kind < 10 {
                    places.open = true
                    pass = true
                }
                let before = feed.observedItems
                work.reset()
                switch kind {
                case 0, 1, 2:
                    pick.title = title
                case 3:
                    pass = pass || observed(other)
                    pick.title = title
                    other.title = title + "-b"
                case 4:
                    places.list.append(Place("n\(seed)-\(made)"))
                    made += 1
                    pass = true
                case 5:
                    // 2 models change places (2 different places: the list has 2 models or more).
                    let from = random.next(below: places.list.count)
                    let to = (from + 1 + random.next(below: places.list.count - 1)) % places.list.count
                    places.list.swapAt(from, to)
                    pass = true
                case 6:
                    // The list changes, then one item of it: the item's change is there before the feed's pass.
                    places.list.insert(Place("n\(seed)-\(made)"), at: random.next(below: places.list.count))
                    made += 1
                    pick.title = title
                    pass = true
                case 7:
                    // One item changes, then the list: the feed's pass can come before the item's change is seen.
                    pick.title = title
                    if places.list.count > 2 {
                        places.list.remove(at: random.next(below: places.list.count))
                        pass = true
                    }
                case 8:
                    // A model changes in the turn in which it leaves the list.
                    pick.title = title
                    if places.list.count > 2 {
                        places.list.removeAll { $0 === pick }
                        pass = true
                    }
                case 9:
                    // A second model under an id that the list has.
                    let twin = Place(pick.id)
                    twin.title = title
                    places.list.insert(twin, at: random.next(below: places.list.count))
                    pass = true
                case 10:
                    places.open.toggle()
                    pass = true
                default:
                    pick.title = title
                    places.open.toggle()
                    pass = true
                }
                await drain()
                if !places.open {
                    want = nil
                } else if pass || want == nil {
                    want = places.list.map(\.title)
                }
                let has = feed.observedItems
                try #require(has == want, """
                    seed \(seed), each id once \(once), step \(step), kind \(kind): the feed has \(String(describing: has)),
                    want \(String(describing: want))
                    """)
                // An owner that takes `update` has the feed's items while there is a list (no update at its end).
                if let has {
                    try #require(kept.items == has, """
                        seed \(seed), each id once \(once), step \(step), kind \(kind): the copy from `update` is
                        \(String(describing: kept.items)), the feed has \(has)
                        """)
                }
                // The path of the step: a pass visits the list's models; items that changed with no visit went in place.
                let listed = work.byStep["ObservedItems.list"] ?? 0
                var inPlace = false
                if listed == 0, let before, let has { inPlace = has != before }
                if once {
                    passedOnce += listed > 0 ? 1 : 0
                    inPlaceOnce += inPlace ? 1 : 0
                } else {
                    passedTwice += listed > 0 ? 1 : 0
                    inPlaceTwice += inPlace ? 1 : 0
                }
            }
        }
        print("observed items feed, 160 steps from each of 8 seeds: with each id once \(inPlaceOnce) steps put items in place and "
            + "\(passedOnce) made a pass over the list; with a second model under one id \(inPlaceTwice) and \(passedTwice)")
        #expect(inPlaceOnce * 2 > 8 * 160,
                "with each id once \(inPlaceOnce) of \(8 * 160) steps put their items in place with no pass, want more than half")
    }
}
