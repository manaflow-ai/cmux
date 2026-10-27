import CmuxNextCompat
import Observation
import Testing

@MainActor @Observable
final class ObservationStreamModel {
    var value = 0
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
    /// later change.
    @Test func anEqualValueIsNotEmittedAgain() async {
        let model = ObservationStreamModel()
        var iterator = ObservationStream { model.value }.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        model.value = 0
        // task-owner: the test's own change, made once the iterator waits on the main actor.
        Task { @MainActor in model.value = 2 }
        #expect(await iterator.next() == 2)
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
