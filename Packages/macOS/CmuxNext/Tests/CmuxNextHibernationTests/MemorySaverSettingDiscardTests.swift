import CmuxNextCompat
import CmuxNextHibernation
import Testing

/// The `memory.saver` mode times the proactive discards of the newer kinds, as
/// Chrome's memory_saver_mode_policy.cc times its tab discards: conservative 1.5x, medium 1x (the
/// timeouts shipped before the setting), aggressive 0.5x of each kind's own timeout, and off none.
/// Critical pressure still discards whatever the mode. A mode change looks again after its turn,
/// never in it.
@MainActor @Suite struct MemorySaverSettingDiscardTests {
    // MARK: Page tabs and conversations (ContentDiscardScheduler)

    private func makeScheduler(mode: MemorySaverMode?) -> (ContentDiscardScheduler, FakeContentHost) {
        let host = FakeContentHost()
        let scheduler = ContentDiscardScheduler(kind: .internalPage)
        scheduler.host = host
        if let mode { scheduler.memorySaverModeDidChange(mode) }
        return (scheduler, host)
    }

    @Test(arguments: [(MemorySaverMode.conservative, 900.0), (.medium, 600), (.aggressive, 300)])
    func aHiddenItemIsDueAfterItsTimeoutInTheMode(mode: MemorySaverMode, seconds: Double) {
        let (scheduler, host) = makeScheduler(mode: mode)
        scheduler.contentDidHide("a")
        #expect(scheduler.nextCheck == seconds, "the 10 min policy in \(mode) is not \(seconds) s")
        withExtendedLifetime(host) {}
    }

    @Test func mediumIsWhatTheSchedulerDidBeforeTheSetting() {
        let (scheduler, host) = makeScheduler(mode: nil)
        #expect(scheduler.saverMode == .medium)
        scheduler.contentDidHide("a")
        #expect(scheduler.nextCheck == 600)
        withExtendedLifetime(host) {}
    }

    @Test func offDiscardsNothingProactivelyButCriticalPressureStillDoes() {
        let (scheduler, host) = makeScheduler(mode: .off)
        scheduler.contentDidHide("a")
        #expect(scheduler.nextCheck == nil, "Memory Saver off armed a proactive discard")
        #expect(!scheduler.hasDeadline)

        scheduler.update(pressure: .critical)
        #expect(scheduler.nextCheck != nil, "critical pressure armed no urgent look with Memory Saver off")
        withExtendedLifetime(host) {}
    }

    @Test func aModeChangeLooksAgainAfterItsTurnOnlyWithHiddenContent() {
        let (scheduler, host) = makeScheduler(mode: .medium)
        scheduler.memorySaverModeDidChange(.aggressive)
        #expect(!scheduler.hasDeadline, "a mode change with nothing hidden armed a look")
        #expect(host.prepared.isEmpty)

        scheduler.contentDidHide("a")
        scheduler.memorySaverModeDidChange(.conservative)
        #expect(scheduler.hasDeadline)
        #expect(scheduler.nextCheck == 0, "the look is not right after the change's turn")
        #expect(host.prepared.isEmpty, "the change planned or prepared a discard in its own turn")
    }

    // MARK: Parked workspaces (ParkedWorkspaceBudget)

    private let deadline = FakeParkDeadline()

    private func makeBudget(mode: MemorySaverMode) -> ParkedWorkspaceBudget {
        let budget = ParkedWorkspaceBudget(capacity: 8, idleTimeout: .seconds(15 * 60), deadline: deadline)
        budget.memorySaverModeDidChange(mode)
        return budget
    }

    @Test(arguments: [(MemorySaverMode.conservative, Duration.seconds(1_350)), (.medium, .seconds(900)), (.aggressive, .seconds(450))])
    func theIdleTimeoutFollowsTheMode(mode: MemorySaverMode, timeout: Duration) throws {
        let budget = makeBudget(mode: mode)
        #expect(budget.idleTimeout == timeout)
        let window = FakeParkWindow()
        window.park("a", in: budget)
        deadline.fire()
        #expect(window.discarded.isEmpty)
        let delay = try #require(deadline.delay, "no idle look was armed")
        #expect(delay <= timeout && delay > timeout - .seconds(1), "the next look is not one idle timeout after the park: \(delay)")
    }

    @Test func offKeepsParkedWorkspacesWithinTheBudget() {
        let budget = makeBudget(mode: .off)
        #expect(budget.idleTimeout == nil)
        let window = FakeParkWindow()
        window.park("a", in: budget)
        #expect(!deadline.armed, "a park within the budget armed a look with Memory Saver off")
    }

    @Test func turningItOffDropsTheIdleLookAfterTheChangesTurn() {
        let budget = makeBudget(mode: .medium)
        let window = FakeParkWindow()
        window.park("a", in: budget)
        deadline.fire()
        #expect(deadline.armed, "no idle look was armed at medium")

        budget.memorySaverModeDidChange(.off)
        #expect(deadline.delay == .zero, "the change did not look again after its turn")
        deadline.fire()
        #expect(!deadline.armed, "the idle look stayed with Memory Saver off")
        #expect(window.discarded.isEmpty)
    }
}

@MainActor
private final class FakeContentHost: ContentDiscardHost {
    private(set) var prepared: [String] = []

    func discardPolicy(of key: String) -> ContentDiscardPolicy? { .standard }
    func keepReasons(of key: String) -> [CannotDiscardReason] { [] }
    func isDrawn(_ key: String) -> Bool { false }
    func prepareDiscard(_ key: String) async -> ContentViewState? {
        prepared.append(key)
        return nil
    }
    func commitDiscard(_ key: String) {}
}

@MainActor
private final class FakeParkWindow: ParkedWorkspaceHolder {
    var showsOnScreen = true
    private(set) var parked: Set<String> = []
    private(set) var discarded: [String] = []

    func park(_ id: String, in budget: ParkedWorkspaceBudget) {
        parked.insert(id)
        budget.didPark(id, in: self)
    }

    func keepsParkedWorkspace(_ id: String) -> Bool { false }

    func discardParkedWorkspace(_ id: String) -> Bool {
        guard parked.remove(id) != nil else { return false }
        discarded.append(id)
        return true
    }
}

@MainActor
private final class FakeParkDeadline: ParkedWorkspaceDeadline {
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
