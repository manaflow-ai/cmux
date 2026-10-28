import CmuxNextCompat
import CmuxNextHibernation
import Testing

/// ``ParkedWorkspaceBudget``: every window's parked workspaces held to one budget,
/// least recently parked first (Chrome's FrameEvictionManager), a 15 min idle timeout on one deadline,
/// and none at critical pressure, one teardown per look or release slice. Fake clock and deadline:
/// nothing waits, nothing polls, and a kept workspace arms no look.
@MainActor @Suite struct ParkedWorkspaceBudgetTests {
    private let clock = FakeClock()
    private let deadline = FakeDeadline()

    private func makeBudget(capacity: Int?, idleTimeout: Duration? = nil, memory: (any MemoryConsumerRegistry)? = nil) -> ParkedWorkspaceBudget {
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
        window.keep(["covered"], in: budget)  // under a top page, or on screen beside the shown one
        window.park("b", in: budget)
        runDueLooks()
        #expect(window.discarded == ["b"], "the kept workspace went, or it did not count against the budget")
        #expect(window.parked == ["covered"])
    }

    @Test func aWorkspaceTheWindowStopsKeepingBecomesTheMostRecentlyParked() {
        let budget = makeBudget(capacity: 2)
        let window = FakeWindow()
        window.park("companion", in: budget)
        window.park("b", in: budget)
        window.keep(["companion"], in: budget)
        runDueLooks()
        window.keep([], in: budget)
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

    @Test func aKeptWorkspaceArmsNoLook() {
        let timeout = Duration.seconds(15 * 60)
        let budget = makeBudget(capacity: 8, idleTimeout: timeout)
        let window = FakeWindow()
        window.park("covered", in: budget)
        window.keep(["covered"], in: budget)
        clock.advance(timeout * 2)
        deadline.fire()
        #expect(window.discarded.isEmpty, "a kept workspace went at its timeout")
        #expect(!deadline.armed, "a kept workspace armed a look: that is polling")
        window.keep(["covered"], in: budget)
        #expect(!deadline.armed, "an arrangement that kept the same workspaces armed a look")
    }

    @Test func aWorkspaceStaysAFullTimeoutAfterTheWindowStopsKeepingIt() {
        let timeout = Duration.seconds(15 * 60)
        let budget = makeBudget(capacity: 8, idleTimeout: timeout)
        let window = FakeWindow()
        window.park("a", in: budget)
        window.kept = ["companion"]  // parked as a companion on screen
        window.park("companion", in: budget)
        deadline.fire()
        #expect(deadline.delay == timeout)

        clock.advance(timeout - .seconds(1))
        window.keep([], in: budget)  // the person left multi-view a second before the look
        #expect(deadline.delay == .zero, "the window stopping keeping a workspace did not ask for a look")
        deadline.fire()
        #expect(window.discarded.isEmpty)
        #expect(deadline.delay == .seconds(1), "the next look is not when a comes due")

        clock.advance(.seconds(1))
        deadline.fire()
        runDueLooks()
        #expect(window.discarded == ["a"], "the workspace that just left the screen went at the old timeout")
        #expect(deadline.delay == timeout - .seconds(1), "its hidden time did not start when it left the screen")

        clock.advance(timeout - .seconds(1))
        deadline.fire()
        runDueLooks()
        #expect(window.discarded == ["a", "companion"])
    }

    @Test func aStopTheWindowDidNotReportErrsLateAtTheNextLook() {
        let timeout = Duration.seconds(15 * 60)
        let budget = makeBudget(capacity: 8, idleTimeout: timeout)
        let window = FakeWindow()
        window.park("a", in: budget)
        window.kept = ["companion"]
        window.park("companion", in: budget)
        deadline.fire()

        clock.advance(timeout - .seconds(60))
        window.kept = []  // no arrangement reported it
        clock.advance(.seconds(60))
        deadline.fire()
        runDueLooks()
        #expect(window.discarded == ["a"], "the companion went though it was hidden for a minute")
        #expect(deadline.delay == timeout, "its hidden time did not start at the look that saw it hidden")
    }

    @Test func aWorkspaceThatLeavesTheScreenAtCriticalGoesOnTheNextLook() {
        let registry = FakeRegistry()
        let budget = makeBudget(capacity: 8, memory: registry)
        let window = FakeWindow()
        window.kept = ["companion"]
        window.park("companion", in: budget)
        budget.updateMemoryLimit(.criticalThreshold)
        #expect(budget.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { false }) == .done)
        runDueLooks()
        #expect(window.discarded.isEmpty, "a workspace on screen went at critical")

        window.keep([], in: budget)
        #expect(window.discarded.isEmpty, "it went in the arrangement's turn")
        runDueLooks()
        #expect(window.discarded == ["companion"], "a workspace that left the screen at critical stayed mounted")
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
        window.keep(["covered"], in: budget)
        runDueLooks()
        #expect(window.discarded.isEmpty)

        budget.updateMemoryLimit(.criticalThreshold)
        #expect(window.discarded.isEmpty, "the new limit released in its own turn")
        #expect(budget.currentCapacity == 0)
        let slice = MemoryReleaseSlice(limit: .criticalThreshold) { false }
        #expect(budget.releaseMemory(within: slice) == .yield, "a teardown did not leave the rest of the slice to the others")
        #expect(window.discarded == ["a"], "a slice did not release the least recently parked one alone")
        #expect(budget.releaseMemory(within: slice) == .yield)
        #expect(budget.releaseMemory(within: slice) == .done, "the last one that may go did not end the release")
        #expect(window.discarded == ["a", "b", "c"])
        #expect(budget.releaseMemory(within: slice) == .done)
        #expect(window.parked == ["covered"], "a kept workspace went at critical")
    }

    /// Pressure takes the workspaces of windows off screen before those of the window
    /// on screen, each least recently parked first.
    @Test func criticalPressureTearsDownOffScreenWindowsFirst() {
        let budget = makeBudget(capacity: nil)
        let shown = FakeWindow(), behind = FakeWindow()
        behind.showsOnScreen = false
        shown.park("s0", in: budget)
        behind.park("b0", in: budget)
        shown.park("s1", in: budget)
        behind.park("b1", in: budget)
        budget.updateMemoryLimit(.criticalThreshold)
        let slice = MemoryReleaseSlice(limit: .criticalThreshold) { false }
        #expect(budget.releaseMemory(within: slice) == .yield)
        #expect(budget.releaseMemory(within: slice) == .yield)
        #expect(behind.discarded == ["b0", "b1"], "a hidden window's workspaces did not go first, least recently parked first")
        #expect(shown.discarded.isEmpty, "the shown window's workspace went before a hidden window's")
        #expect(budget.releaseMemory(within: slice) == .yield)
        #expect(budget.releaseMemory(within: slice) == .done)
        #expect(shown.discarded == ["s0", "s1"])
    }

    /// With no budget (`memoryDiscardParkedWorkspaces` off) a park arms no look and nothing goes
    /// until critical pressure, which tears every workspace down one per slice.
    @Test func withNoBudgetOnlyCriticalPressureTearsDown() {
        let budget = makeBudget(capacity: nil)
        let window = FakeWindow()
        for id in (0..<20).map({ "w\($0)" }) { window.park(id, in: budget) }
        #expect(!deadline.armed, "a park with no budget and no timeout armed a look")
        budget.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(budget.releaseMemory(within: MemoryReleaseSlice(limit: MemoryLimit(percent: 50)) { false }) == .done)
        #expect(window.discarded.isEmpty)

        budget.updateMemoryLimit(.criticalThreshold)
        let slice = MemoryReleaseSlice(limit: .criticalThreshold) { false }
        var slices = 0
        while budget.releaseMemory(within: slice) == .yield { slices += 1 }
        #expect(slices == 19)
        #expect(window.discarded == (0..<20).map { "w\($0)" })
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
    var showsOnScreen = true
    private(set) var parked: Set<String> = []
    var kept: Set<String> = []
    private(set) var discarded: [String] = []

    func park(_ id: String, in budget: ParkedWorkspaceBudget) {
        parked.insert(id)
        budget.didPark(id, in: self)
    }

    /// The window arranged its content: it keeps `ids` now and tells the budget.
    func keep(_ ids: Set<String>, in budget: ParkedWorkspaceBudget) {
        kept = ids
        budget.keepingDidChange(in: self)
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
