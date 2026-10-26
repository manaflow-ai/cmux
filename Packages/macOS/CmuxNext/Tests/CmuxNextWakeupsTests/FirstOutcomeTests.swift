import CmuxNextWakeups
import Testing

/// FirstOutcome over OnceContinuation (p10-stability-088): the first resolve wins, and every waiter
/// gets it, whether it waited before or after the resolve.
@Suite(.timeLimit(.minutes(1))) struct FirstOutcomeTests {
    @Test func aWaiterAfterTheResolveGetsTheFirstValue() async {
        let outcome = FirstOutcome<Int>()
        outcome.resolve(1)
        outcome.resolve(2)
        #expect(await outcome.value() == 1)
    }

    /// Two waiters at once: before, the second replaced the first's continuation and the first
    /// never returned.
    @Test func everyConcurrentWaiterGetsTheFirstValue() async {
        let outcome = FirstOutcome<String>()
        async let first = outcome.value()
        async let second = outcome.value()
        outcome.resolve("first")
        outcome.resolve("late")
        #expect(await [first, second] == ["first", "first"])
    }

    @Test func aNilValueIsAValue() async {
        let outcome = FirstOutcome<Int?>()
        outcome.resolve(nil)
        outcome.resolve(3)
        #expect(await outcome.value() == nil)
    }
}
