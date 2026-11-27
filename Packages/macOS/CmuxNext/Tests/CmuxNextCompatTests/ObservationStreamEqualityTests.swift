@testable import CmuxNextCompat
import Observation
import Testing

/// REOPEN-F7 (launch stalls, feat 287ad03, 20 warm reopens): right after the first window was built, 26-31 ms of
/// main-thread work ran before the first window frame's mark, most of it in `ObservationStream.makeAsyncIterator`
/// asking the runtime whether each stream's element is `Equatable` (a conformance lookup that scans the binary's
/// conformance records the first time per type). An `Equatable` element is known to be one where the stream is made:
/// its stream must ask the runtime nothing, and still skip an equal value.
@MainActor
@Suite struct ObservationStreamEqualityTests {
    /// `nonisolated`: under the module's default main-actor isolation (InferIsolatedConformances) a type's own
    /// `Equatable` conformance is main-actor isolated, and an isolated conformance cannot meet `Element: Equatable`
    /// on a `Sendable` element; such a stream keeps the run-time lookup. Standard library values (Bool, Int,
    /// String, their optionals and collections) and nonisolated types take the known `==`.
    nonisolated struct Count: Equatable, Sendable { var value: Int }
    struct Opaque: Sendable { var value: Int }

    /// A type of this module: main-actor isolated, so its `Equatable` conformance is too (the app modules' case):
    /// its streams look `==` up at run time.
    struct Mark: Equatable, Sendable { var value: Int }

    @MainActor @Observable final class Box {
        var count = Count(value: 0)
        var opaque = Opaque(value: 0)
        var mark = Mark(value: 0)
    }

    /// REOPEN-F7 (9 of 10 sampled stalls of the turn after a reopen's first window commit, cmux18 job cea96828): the
    /// lookup ran in `makeAsyncIterator` for every stream of an app type. The first value needs no `==`: the lookup
    /// waits for the second, and then dedupes as before.
    @Test func anAppTypeStreamLooksUpEqualityOnlyWhenASecondValueComes() async {
        let box = Box()
        var values = ObservationStream({ box.mark }).makeAsyncIterator()
        guard case .unresolved = values.equality else {
            Issue.record("the stream looked up Equatable at run time before its first value")
            return
        }
        #expect(await values.next() == Mark(value: 0))
        guard case .unresolved = values.equality else {
            Issue.record("the first value looked up Equatable at run time")
            return
        }
        Task { @MainActor in
            box.mark = Mark(value: 0) // equal: wakes no consumer
            await Task.yield()
            box.mark = Mark(value: 1)
        }
        #expect(await values.next() == Mark(value: 1))
        guard case .known = values.equality else {
            Issue.record("the second value did not resolve ==")
            return
        }
    }

    @Test func anEquatableStreamAsksTheRuntimeNothing() async {
        let box = Box()
        let stream = ObservationStream({ box.count })
        #expect(stream.knownEquality != nil, "the stream looks up Equatable at run time for an element known to be Equatable")
        var values = stream.makeAsyncIterator()
        #expect(await values.next() == Count(value: 0))
    }

    @Test func anEquatableStreamStillSkipsAnEqualValue() async {
        let box = Box()
        var values = ObservationStream({ box.count }).makeAsyncIterator()
        #expect(await values.next() == Count(value: 0))
        Task { @MainActor in
            box.count = Count(value: 0) // equal: wakes no consumer
            await Task.yield()
            box.count = Count(value: 1)
        }
        #expect(await values.next() == Count(value: 1))
    }

    @Test func aStreamOfAnotherElementEmitsEveryValueAsBefore() async {
        let box = Box()
        let stream = ObservationStream({ box.opaque })
        #expect(stream.knownEquality == nil)
        var values = stream.makeAsyncIterator()
        #expect(await values.next()?.value == 0)
        Task { @MainActor in box.opaque = Opaque(value: 0) }
        #expect(await values.next()?.value == 0, "a value that is not Equatable is emitted on every change")
    }
}
