import CmuxNextCompat
import Observation
import Testing

@MainActor @Observable
final class ObservationStreamModel {
    var value = 0
    /// The stream expression's evaluations, read without tracking.
    @ObservationIgnored var reads = 0
}

/// `ObservationStream`'s `withObservationTracking` path, the one every OS runs (macOS 14 to 27, and Linux for
/// the tier's Compat tests): the first value at once, then the value after each change, never a stale one.
@MainActor
struct ObservationStreamTests {
    @Test func theFirstValueThenTheValueAfterAChange() async {
        let model = ObservationStreamModel()
        var iterator = ObservationStream { model.value }.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        model.value = 1
        #expect(await iterator.next() == 1)
    }

    /// A change back to the emitted value wakes no consumer with it: the next value is the one after the
    /// later change. Observation ignores an equal set, so the test changes the value and sets it back in one
    /// turn; the re-evaluation then reads the emitted 0, which the dedupe must skip. The later change starts
    /// only from that re-evaluation, so it cannot reach the stream first.
    @Test func anEqualValueIsNotEmittedAgain() async {
        let model = ObservationStreamModel()
        var iterator = ObservationStream { () -> Int in
            model.reads += 1
            if model.reads == 2 {
                // task-owner: the test's own later change, made after the stream read the equal value.
                Task { @MainActor in model.value = 2 }
            }
            return model.value
        }.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        model.value = 1
        model.value = 0
        #expect(await iterator.next() == 2)
        #expect(model.reads == 3)
    }

    /// `current(_:)` returns the first value in the caller's turn; its stream's first `next()` is the change.
    @Test func theCurrentValueThenTheChange() async {
        let model = ObservationStreamModel()
        let (value, later) = ObservationStream.current { model.value }
        #expect(value == 0)
        var iterator = later.makeAsyncIterator()
        model.value = 3
        #expect(await iterator.next() == 3)
    }
}
