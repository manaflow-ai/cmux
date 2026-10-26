import CmuxNextCompat
import CmuxNextHibernation
import Testing

/// ``ParkedWorkspaceBudget`` (p07-memory-032): every window's parked workspaces held to one budget,
/// least recently parked first (Chrome's FrameEvictionManager), a 15 min idle timeout on one deadline,
/// and none at critical pressure, one teardown per look or release slice. Fake clock and deadline:
/// nothing waits, nothing polls.
@MainActor @Suite struct ParkedWorkspaceBudgetTests {
    private let clock = FakeClock()
    private let deadline = FakeDeadline()

    private func makeBudget(capacity: Int, idleTimeout: Duration? = nil, memory: (any MemoryConsumerRegistry)? = nil) -> ParkedWorkspaceBudget {
        ParkedWorkspaceBudget(capacity: capacity, idleTimeout: idleTimeout, deadline: deadline, memory: memory) { [clock] in clock.now }
    }

    /// Runs the armed looks, as the deadline would, until none is due at once (at most `limit`).
    private func runDueLooks(limit: Int = 50) {
        for _ in 0..<limit {
            guard deadline.delay == .zero else { return }
            deadline.fire()
        }
    }

    @Test func pastTheBudgetTheLeastRecentlyParkedGoesFirstAcrossWindows() {
        let budget = makeBudget(capacity: 2)
        let left = FakeWindow(), right = FakeWindow()
        left.park("a", in: budget)
        right.park("b", in: budget)
        left.park("c", in: budget)
        right.park("d", in: budget)
        #expect(left.discarded.isEmpty && right.discarded.isEmpty, "a teardown ran in the park's turn")
        #expect(deadline.delay == .zero, "the look is not right after the park's turn")

        deadline.fire()
        #expect(left.discarded == ["a"], "the least recently parked workspace did not go first")
        #expect(right.discarded.isEmpty, "a look tore down more than one workspace")
        #expect(deadline.delay == .zero, "the next look is not on the next task while over the budget")

        deadline.fire()
        #expect(right.discarded == ["b"])
        #expect(budget.parkedCount == 2)
        #expect(!deadline.armed, "a look within the budget with no timeout armed a deadline")
        #expect(budget.discardedCount == 2)
    }

    @Test func aWorkspaceShownAgainNoLongerCounts() {
        let budget = makeBudget(capacity: 2)
        let window = FakeWindow()
        for id in ["a", "b", "c"] { window.park(id, in: budget) }
        window.show("a", in: budget)
        runDueLooks()
        #expect(window.discarded.isEmpty, "a workspace went though the shown one left the budget")
        #expect(budget.parkedCount == 2)
    }

    @Test func aKeptWorkspaceCountsButStaysAndTheNextOneGoes() {
        let budget = makeBudget(capacity: 1)
        let window = FakeWindow()
        window.park("covered", in: budget)
        window.kept = ["covered"]  // under a top page, or on screen beside the shown one
        window.park("b", in: budget)
        runDueLooks()
        #expect(window.discarded == ["b"], "the kept workspace went, or it did not count against the budget")
        #expect(window.parked == ["covered"])
    }

    @Test func aKeptWorkspaceBecomesTheMostRecentlyParked() {
        let budget = makeBudget(capacity: 2)
        let window = FakeWindow()
        window.park("companion", in: budget)
        window.park("b", in: budget)
        window.kept = ["companion"]
        runDueLooks()  // the look sees it on screen
        window.kept = []
        window.park("c", in: budget)
        runDueLooks()
        #expect(window.discarded == ["b"], "a workspace just on screen went before an older hidden one")
    }

    @Test func aClosedWindowsWorkspacesStopCounting() {
        let budget = makeBudget(capacity: 1)
        var closing: FakeWindow? = FakeWindow()
        let other = FakeWindow()
        closing?.park("a", in: budget)
        if let closing { budget.forgetAll(in: closing) }
        closing = nil
        other.park("b", in: budget)
        runDueLooks()
        #expect(other.discarded.isEmpty)
        #expect(budget.parkedCount == 1)
    }

    @Test func theIdleTimeoutTearsDownTheLongestHiddenOneOnOneDeadline() {
        let budget = makeBudget(capacity: 8, idleTimeout: .seconds(15 * 60))
        let window = FakeWindow()
        window.park("a", in: budget)
        clock.advance(.seconds(5 * 60))
        window.park("b", in: budget)
        deadline.fire()
        #expect(window.discarded.isEmpty)
        #expect(deadline.delay == .seconds(10 * 60), "the deadline is not when the longest hidden one comes due")

        clock.advance(.seconds(10 * 60))
        deadline.fire()
        #expect(window.discarded == ["a"])
        #expect(deadline.delay == .zero)
        deadline.fire()
        #expect(window.discarded == ["a"], "b went before its own timeout")
        #expect(deadline.delay == .seconds(5 * 60))

        clock.advance(.seconds(5 * 60))
        deadline.fire()
        runDueLooks()
        #expect(window.discarded == ["a", "b"])
        #expect(!deadline.armed, "a deadline stayed with nothing parked")
    }

    @Test func aKeptWorkspaceIsLookedAtAgainATimeoutLaterAndItsHiddenTimeRestarts() {
        let timeout = Duration.seconds(15 * 60)
        let budget = makeBudget(capacity: 8, idleTimeout: timeout)
        let window = FakeWindow()
        window.park("covered", in: budget)
        window.kept = ["covered"]
        clock.advance(timeout * 2)
        deadline.fire()
        #expect(window.discarded.isEmpty, "a kept workspace went at its timeout")
        #expect(deadline.delay == timeout)

        window.kept = []
        clock.advance(timeout - .seconds(1))
        deadline.fire()
        #expect(window.discarded.isEmpty, "its hidden time counted from the park, not from when it was last in use")
        #expect(deadline.delay == .seconds(1))
    }

    @Test func withoutATimeoutAWorkspaceWithinTheBudgetStaysForever() {
        let budget = makeBudget(capacity: 4)
        let window = FakeWindow()
        window.park("a", in: budget)
        clock.advance(.seconds(24 * 60 * 60))
        deadline.fire()
        #expect(window.discarded.isEmpty)
        #expect(!deadline.armed)
    }

    @Test func criticalPressureReleasesOneWorkspacePerSliceAndKeepsTheKeptOnes() {
        let registry = FakeRegistry()
        let budget = makeBudget(capacity: 8, memory: registry)
        #expect(registry.entries.first?.traits == ParkedWorkspaceBudget.memoryTraits)
        #expect(budget.limit == .default, "the registration did not hand it the current limit")
        let window = FakeWindow()
        for id in ["a", "b", "c", "covered"] { window.park(id, in: budget) }
        window.kept = ["covered"]
        runDueLooks()
        #expect(window.discarded.isEmpty)

        budget.updateMemoryLimit(.criticalThreshold)
        #expect(window.discarded.isEmpty, "the new limit released in its own turn")
        #expect(budget.currentCapacity == 0)
        let slice = MemoryReleaseSlice(limit: .criticalThreshold) { false }
        #expect(budget.releaseMemory(within: slice) == .more)
        #expect(window.discarded == ["a"], "a slice did not release the least recently parked one alone")
        #expect(budget.releaseMemory(within: slice) == .more)
        #expect(budget.releaseMemory(within: slice) == .done, "the last one that may go did not end the release")
        #expect(window.discarded == ["a", "b", "c"])
        #expect(budget.releaseMemory(within: slice) == .done)
        #expect(window.parked == ["covered"], "a kept workspace went at critical")
    }

    @Test func aWorkspaceParkedAtCriticalGoesOnTheNextLook() {
        let budget = makeBudget(capacity: 8)
        budget.updateMemoryLimit(.criticalThreshold)
        let window = FakeWindow()
        window.park("a", in: budget)
        #expect(window.discarded.isEmpty)
        runDueLooks()
        #expect(window.discarded == ["a"])
    }

    @Test func normalPressureAgainMakesNoRelease() {
        let budget = makeBudget(capacity: 2)
        let window = FakeWindow()
        for id in ["a", "b"] { window.park(id, in: budget) }
        runDueLooks()
        budget.updateMemoryLimit(.criticalThreshold)
        budget.updateMemoryLimit(.default)
        #expect(budget.releaseMemory(within: MemoryReleaseSlice(limit: .default) { false }) == .done)
        #expect(window.discarded.isEmpty)
    }
}

@MainActor
private final class FakeWindow: ParkedWorkspaceHolder {
    private(set) var parked: Set<String> = []
    var kept: Set<String> = []
    private(set) var discarded: [String] = []

    func park(_ id: String, in budget: ParkedWorkspaceBudget) {
        parked.insert(id)
        budget.didPark(id, in: self)
    }

    func show(_ id: String, in budget: ParkedWorkspaceBudget) {
        parked.remove(id)
        budget.forget(id, in: self)
    }

    func keepsParkedWorkspace(_ id: String) -> Bool { kept.contains(id) }

    func discardParkedWorkspace(_ id: String) -> Bool {
        guard parked.remove(id) != nil else { return false }
        discarded.append(id)
        return true
    }
}

@MainActor
private final class FakeDeadline: ParkedWorkspaceDeadline {
    private(set) var delay: Duration?
    private var action: (@MainActor () -> Void)?
    var armed: Bool { action != nil }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func cancel() {
        delay = nil
        action = nil
    }

    func fire() {
        guard let action else { return }
        self.action = nil
        delay = nil
        action()
    }
}

@MainActor
private final class FakeClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

@MainActor
private final class FakeRegistry: MemoryConsumerRegistry {
    private(set) var entries: [MemoryConsumerEntry] = []

    func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        entries.append(entry)
        entry.consumer?.updateMemoryLimit(.default)
    }
}
