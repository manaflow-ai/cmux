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
        init(_ title: String) { self.title = title }
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

    /// `workspace`'s parts from `kept`, with each call of `make` written to `made`.
    private func titles(_ kept: KeptParts<Workspace, Tab, String>, _ workspace: Workspace, _ made: Made) -> [String] {
        kept.parts(of: workspace, workspace.tabs) { tab in
            made.titles.append(tab.title)
            return tab.title
        }
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
}
