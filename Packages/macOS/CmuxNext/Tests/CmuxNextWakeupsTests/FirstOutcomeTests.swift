import CmuxNextWakeups
import Testing

/// FirstOutcome's waits are OnceContinuations. Each waiter gets the first value: a second
/// `value()` made before the resolve no longer replaces the first waiter's continuation (which left that task
/// waiting for ever), and a wait after the resolve returns at once.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FirstOutcomeTests {
    @Test func everyWaiterBeforeTheResolveGetsTheFirstValue() async {
        let outcome = FirstOutcome<Int>()
        // Main-actor jobs run in the order they were made: both waits file themselves before the resolve runs.
        let first = Task { await outcome.value() }
        let second = Task { await outcome.value() }
        let resolve = Task {
            outcome.resolve(1)
            outcome.resolve(2)
        }
        await resolve.value
        #expect(await first.value == 1)
        #expect(await second.value == 1)
    }

    @Test func aWaitAfterTheResolveReturnsTheFirstValueAtOnce() async {
        let outcome = FirstOutcome<String>()
        outcome.resolve("first")
        outcome.resolve("second")
        #expect(await outcome.value() == "first")
        #expect(await outcome.value() == "first")
    }
}
