import CmuxNextCompat
import Observation
import Testing

/// `KeptParts` keeps one part for each model of an owner, each under its own observation: a model that changes
/// makes its own part again and no other model's, a caller that runs under an observation hears the change of a
/// kept part, and a model that left the list has no part and no observation.
@MainActor
@Suite struct KeptPartsTests {
    @MainActor @Observable final class Tab {
        var title: String
        /// Read only by a part that has a tag (``tagged(_:_:_:_:)``).
        var badge = ""
        init(_ title: String) { self.title = title }
    }

    /// A tag for each tab in a store that is not observable: a change of one wakes no observation.
    @MainActor final class Tags {
        private var tags: [ObjectIdentifier: String] = [:]
        func tag(of tab: Tab) -> String { tags[ObjectIdentifier(tab)] ?? "" }
        func set(_ tag: String, of tab: Tab) { tags[ObjectIdentifier(tab)] = tag }
    }

    @MainActor @Observable final class Workspace {
        var tabs: [Tab]
        init(_ tabs: [Tab]) { self.tabs = tabs }
    }

    /// The titles that `make` read, in the order of its calls.
    @MainActor final class Made {
        var titles: [String] = []
    }

    /// Set by a change callback, which is not isolated.
    nonisolated final class Heard: Sendable {
        private let heard = Atomic<Bool>(false)
        var value: Bool { heard.load(ordering: .acquiring) }
        func hear() { heard.store(true, ordering: .releasing) }
    }

    /// The calls of a change callback, which is not isolated.
    nonisolated final class Calls: Sendable {
        private let calls = Atomic<Int>(0)
        var count: Int { calls.load(ordering: .acquiring) }
        func add() { calls.add(1, ordering: .acquiringAndReleasing) }
    }

    /// The rounds of a test of one change's callbacks: the order in which the system calls the callbacks of one
    /// change is not fixed, and it differs from round to round.
    static let rounds = 40

    /// `workspace`'s parts from `kept`, with each call of `make` written to `made`.
    private func titles(_ kept: KeptParts<Workspace, Tab, String>, _ workspace: Workspace, _ made: Made) -> [String] {
        kept.parts(of: workspace, workspace.tabs) { tab in
            made.titles.append(tab.title)
            return tab.title
        }
    }

    /// `workspace`'s parts from `kept`, each with its tab's tag as its input: a tab with no tag reads as its title,
    /// and a tab with a tag as its title, its badge and the tag. Each call of `make` is written to `made`.
    private func tagged(_ kept: KeptParts<Workspace, Tab, String>, _ workspace: Workspace, _ tags: Tags, _ made: Made) -> [String] {
        kept.parts(of: workspace, workspace.tabs, input: { tags.tag(of: $0) }, make: { tab, tag in
            let part = tag.isEmpty ? tab.title : tab.title + tab.badge + tag
            made.titles.append(part)
            return part
        })
    }

    @Test func aPartIsKeptForItsInputAndAnotherInputMakesOnlyThatModelsPartAgain() {
        let workspace = Workspace([Tab("a"), Tab("b"), Tab("c")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let (tags, made, work) = (Tags(), Made(), ObservationWork())
        #expect(tagged(kept, workspace, tags, made) == ["a", "b", "c"])
        #expect(tagged(kept, workspace, tags, made) == ["a", "b", "c"])
        #expect(made.titles == ["a", "b", "c"], "a call with each input as before made a part")

        // No observation hears this change: the part follows it by its input at the next call.
        tags.set("!", of: workspace.tabs[1])
        let parts = ObservationWork.$current.withValue(work) { tagged(kept, workspace, tags, made) }
        #expect(parts == ["a", "b!", "c"], "a kept part does not follow its input")
        #expect(made.titles == ["a", "b", "c", "b!"], "one model's input changed: only its own part is made again")
        #expect(work.byStep["KeptPartsTests.parts"] == 1, "a part made again for another input is counted")
        #expect(tagged(kept, workspace, tags, made) == ["a", "b!", "c"])
        #expect(made.titles == ["a", "b", "c", "b!"], "the part made for the new input is kept")
    }

    /// A part made again for another input reads other values than the part before it. Its observation is of what
    /// it read itself: a value that only the new part read makes it again and wakes a caller.
    @Test func aPartMadeForAnotherInputIsUnderItsOwnObservation() {
        let workspace = Workspace([Tab("a"), Tab("b")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let (tags, made) = (Tags(), Made())
        _ = tagged(kept, workspace, tags, made)
        tags.set("!", of: workspace.tabs[0])
        #expect(tagged(kept, workspace, tags, made) == ["a!", "b"])
        #expect(made.titles == ["a", "b", "a!"], "setup: the tab's part is not made again for its tag")

        // This call makes no part, so the caller's observation reads no model's badge itself.
        let heard = Heard()
        let caller = SingleArmedTracking()
        _ = caller.track(shape: [], { tagged(kept, workspace, tags, made) }, onChange: { heard.hear() })
        #expect(made.titles == ["a", "b", "a!"], "setup: the call under the observation made a part")

        workspace.tabs[0].badge = "+"
        #expect(heard.value, "the caller did not hear a value that only the part of the new input read")
        #expect(tagged(kept, workspace, tags, made) == ["a+!", "b"], "the part of the new input does not follow what it read")
        #expect(made.titles == ["a", "b", "a!", "a+!"])

        // The part of the input before read no badge: with no tag the tab's badge makes no part.
        workspace.tabs[1].badge = "+"
        #expect(tagged(kept, workspace, tags, made) == ["a+!", "b"])
        #expect(made.titles == ["a", "b", "a!", "a+!"], "a value that a part did not read made it again")
    }

    @Test func withNoHolderEachPartIsMadeFromItsInput() {
        let workspace = Workspace([Tab("a"), Tab("bb")])
        let parts = KeptParts<Workspace, Tab, String>.parts(of: workspace, workspace.tabs, kept: nil, input: { $0.title.count }, make: { "\($0.title)\($1)" })
        #expect(parts == ["a1", "bb2"])
    }

    @Test func aPartIsMadeOnceAndAModelThatChangesMakesOnlyItsOwnPartAgain() {
        let workspace = Workspace([Tab("a"), Tab("b"), Tab("c")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let made = Made()
        #expect(titles(kept, workspace, made) == ["a", "b", "c"])
        #expect(made.titles == ["a", "b", "c"], "the first call makes each model's part")
        #expect(titles(kept, workspace, made) == ["a", "b", "c"])
        #expect(made.titles == ["a", "b", "c"], "a call after no change makes no part")

        workspace.tabs[1].title = "B"
        #expect(titles(kept, workspace, made) == ["a", "B", "c"])
        #expect(made.titles == ["a", "b", "c", "B"], "one model changed: only its own part is made again")
        #expect(titles(kept, workspace, made) == ["a", "B", "c"])
        #expect(made.titles == ["a", "b", "c", "B"], "the part made again is kept")
    }

    @Test func aModelThatComesMakesItsOwnPartAndAModelThatGoesMakesNone() {
        let workspace = Workspace([Tab("a"), Tab("b"), Tab("c")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let made = Made()
        _ = titles(kept, workspace, made)
        made.titles.removeAll()

        workspace.tabs.insert(Tab("n"), at: 1)
        #expect(titles(kept, workspace, made) == ["a", "n", "b", "c"], "the parts are in the list's order")
        #expect(made.titles == ["n"], "a model that comes makes its own part and no other")

        let gone = workspace.tabs.remove(at: 2)
        #expect(titles(kept, workspace, made) == ["a", "n", "c"])
        #expect(made.titles == ["n"], "a model that goes makes no part")

        // The model that left comes back changed: its part is not the one kept before it left.
        gone.title = "back"
        workspace.tabs.append(gone)
        #expect(titles(kept, workspace, made) == ["a", "n", "c", "back"])
        #expect(made.titles == ["n", "back"])
    }

    @Test func aCallerUnderAnObservationHearsTheChangeOfAKeptPart() {
        let workspace = Workspace([Tab("a"), Tab("b")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let made = Made()
        _ = titles(kept, workspace, made)
        // This call makes no part, so the caller's observation reads no model's title itself.
        let heard = Heard()
        let caller = SingleArmedTracking()
        let first = caller.track(shape: [], { titles(kept, workspace, made) }, onChange: { heard.hear() })
        #expect(first == ["a", "b"])
        #expect(made.titles == ["a", "b"], "setup: the call under the observation made a part")
        #expect(!heard.value)

        workspace.tabs[0].title = "A"
        #expect(heard.value, "the caller did not hear the change of a kept part")
        #expect(titles(kept, workspace, made) == ["A", "b"])
    }

    @Test func aModelThatLeftTheListWakesNoCaller() {
        let workspace = Workspace([Tab("a"), Tab("b")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let made = Made()
        _ = titles(kept, workspace, made)
        let gone = workspace.tabs.removeLast()
        _ = titles(kept, workspace, made)

        let heard = Heard()
        let caller = SingleArmedTracking()
        _ = caller.track(shape: [], { kept.parts(of: workspace, workspace.tabs) { $0.title } }, onChange: { heard.hear() })
        gone.title = "changed after it left"
        #expect(!heard.value, "a model that left the list woke the caller")
        #expect(titles(kept, workspace, made) == ["a"])
        #expect(made.titles == ["a", "b"], "a change of a model that left made a part")
    }

    @Test func eachOwnerHasItsOwnParts() {
        let shared = Tab("s")
        let (one, two) = (Workspace([shared, Tab("a")]), Workspace([shared]))
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let made = Made()
        #expect(titles(kept, one, made) == ["s", "a"])
        #expect(titles(kept, two, made) == ["s"])
        #expect(made.titles == ["s", "a", "s"], "an owner's part is not another owner's")

        one.tabs.removeAll()
        #expect(titles(kept, one, made).isEmpty)
        #expect(titles(kept, two, made) == ["s"])
        #expect(made.titles == ["s", "a", "s"], "an owner whose models left removed the part of another owner")
    }

    @Test func thePartsMadeAreCountedForATest() {
        let workspace = Workspace([Tab("a"), Tab("b"), Tab("c")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let made = Made()
        let work = ObservationWork()
        ObservationWork.$current.withValue(work) { _ = titles(kept, workspace, made) }
        #expect(work.byStep["KeptPartsTests.parts"] == 3)
        work.reset()
        workspace.tabs[2].title = "C"
        ObservationWork.$current.withValue(work) { _ = titles(kept, workspace, made) }
        #expect(work.byStep["KeptPartsTests.parts"] == 1)
    }

    /// A caller that made a part in its own call read 2 things for that part's model: the model's title (a part's
    /// `make` runs inside the caller's observation too) and the owner's cell. The part's callback moves the cell
    /// inside the title's change. The caller hears that one change one time.
    @Test func aCallerHearsOneChangeOfAPartThatItMadeOneTime() {
        let workspace = Workspace([Tab("a"), Tab("b")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let made = Made()
        let calls = Calls()
        let caller = SingleArmedTracking()
        for round in 0 ..< Self.rounds {
            // This call makes the part of the tab that changed in the round before (each part in the first round).
            _ = caller.track(shape: [], { titles(kept, workspace, made) }, onChange: { calls.add() })
            workspace.tabs[0].title = "round \(round)"
        }
        #expect(made.titles.count == 2 + Self.rounds - 1, "setup: the caller's calls did not make the changed tab's part each round")
        #expect(calls.count == Self.rounds, "the caller's callback ran \(calls.count) times for \(Self.rounds) changes of one tab, one change in each round")
    }

    /// The feed's form: a stream whose value is joined from the kept parts evaluates one time for one change, while
    /// its consumer waits for the next value.
    @Test func aStreamOverKeptPartsEvaluatesOneTimeForOneChange() async {
        let workspace = Workspace([Tab("a"), Tab("b")])
        let kept = KeptParts<Workspace, Tab, String>(step: "KeptPartsTests.parts")
        let evaluations = Calls()
        let (first, later) = ObservationStream.current({
            evaluations.add()
            return kept.parts(of: workspace, workspace.tabs) { $0.title }
        })
        #expect(first == ["a", "b"])
        var values = later.makeAsyncIterator()
        for round in 0 ..< Self.rounds {
            // The change comes while this test waits in `next()`.
            Task { @MainActor in workspace.tabs[0].title = "round \(round)" }
            let next = await values.next()
            #expect(next == ["round \(round)", "b"])
        }
        #expect(evaluations.count == 1 + Self.rounds, "the stream evaluated \(evaluations.count) times for its first value and \(Self.rounds) changes of one tab")
    }

    /// A report of the system's own rule, with no condition on its count: a registration that read 2 values has
    /// its callback called 2 times in one change of the first value when a callback before it moves the second
    /// value. `SingleArmedTracking` and `ObservationStream` count such a registration one time.
    @Test func theSystemCanCallOneRegistrationsCallbackTwoTimesInOneChange() {
        let (tab, cell) = (Tab("a"), Tab("cell"))
        let calls = Calls()
        var twice = 0
        for round in 0 ..< Self.rounds {
            let before = calls.count
            // The outer registration reads what the inner one read (the title) and the cell.
            withObservationTracking {
                withObservationTracking { _ = tab.title } onChange: { MainActor.assumeIsolated { cell.title = "moved in round \(round)" } }
                _ = cell.title
            } onChange: { calls.add() }
            tab.title = "round \(round)"
            let ran = calls.count - before
            #expect(ran == 1 || ran == 2, "the outer registration's callback ran \(ran) times for one change in round \(round)")
            if ran == 2 { twice += 1 }
        }
        print("TAB-PARTS the system's callbacks: in \(twice) of \(Self.rounds) rounds the outer registration's callback ran 2 times for one change")
    }
}
