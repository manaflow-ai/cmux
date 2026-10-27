import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The handler waits of file group 305 that race a `ServiceObservation` against a `MainDeadline`
/// (p06-scheduler.md rule 9, one harness case per migrated owner class): a Cloud reveal's mount
/// wait (userBlocking: it selects once on mount, in the run scope of its caller, and its limit
/// cancels the observation) and `cloud new-machine`'s settle wait (automation: it yields to the
/// person's pending input, resumes once when the creation settles, and resumes nil at its limit).
/// Nothing fires on its own: the test runs the posted turns, the frames and the wake.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FirstValueWaitTests {
    @MainActor @Observable final class Mount {
        var controller: Controller?
    }

    /// Stands for a mounted `PaneController`.
    @MainActor final class Controller {}

    /// What the reveal's select saw, per call.
    @MainActor final class Selects {
        var allowed: [Bool] = []
    }

    // MARK: Reveal (userBlocking)

    @Test func aMountAlreadyThereSelectsBeforeTheWaitStarts() {
        let rig = WatchRig()
        let mount = Mount(), selects = Selects()
        mount.controller = Controller()
        let watch = CloudHandlers.selectWhenMounted(work: rig.work, deadlines: rig.deadlines, find: { mount.controller }) { _ in
            selects.allowed.append(ActionRunScope.viewChangeAllowed())
        }
        #expect(selects.allowed == [true])
        #expect(!watch.isWaiting)
        #expect(watch.observation == nil)
        #expect(!rig.isArmed, "a limit was armed for a wait that never started")
    }

    @Test func aPaneThatMountsAfterTheRevealIsSelectedOnce() {
        let rig = WatchRig()
        let mount = Mount(), selects = Selects()
        let watch = CloudHandlers.selectWhenMounted(work: rig.work, deadlines: rig.deadlines, find: { mount.controller }) { _ in
            selects.allowed.append(ActionRunScope.viewChangeAllowed())
        }
        #expect(selects.allowed.isEmpty)
        #expect(rig.isArmed)
        let observation = watch.observation
        #expect(observation != nil, "the wait did not observe the mount")

        mount.controller = Controller()
        rig.step()
        #expect(selects.allowed == [true], "the mount was not selected once")
        #expect(observation?.isCancelled == true)
        #expect(!rig.isArmed, "the limit stayed armed after the mount")

        mount.controller = Controller()
        rig.step()
        #expect(selects.allowed == [true], "a second mount selected again")
    }

    /// A CLI run without `focus: true` keeps its permission after the pane mounts in a later turn:
    /// the select runs in the reveal's run scope, not in no scope (which allows every change).
    @Test func aLateMountKeepsTheRunsViewChangePermission() {
        let rig = WatchRig()
        let mount = Mount(), selects = Selects()
        let watch = ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            CloudHandlers.selectWhenMounted(work: rig.work, deadlines: rig.deadlines, find: { mount.controller }) { _ in
                selects.allowed.append(ActionRunScope.viewChangeAllowed())
            }
        }
        #expect(ActionRunScope.current == nil)

        mount.controller = Controller()
        rig.step()
        #expect(selects.allowed == [false], "the late select ran without the run's scope")
        #expect(!watch.isWaiting)
    }

    @Test func theRevealLimitCancelsTheObservationAndSelectsNothing() {
        let rig = WatchRig()
        let mount = Mount(), selects = Selects()
        let watch = CloudHandlers.selectWhenMounted(work: rig.work, deadlines: rig.deadlines, find: { mount.controller }) { _ in
            selects.allowed.append(ActionRunScope.viewChangeAllowed())
        }
        let observation = watch.observation

        rig.fireAndRun()
        #expect(!watch.isWaiting, "the limit did not end the wait")
        #expect(observation?.isCancelled == true, "the limit left the observation running")
        #expect(watch.observation == nil)

        mount.controller = Controller()
        rig.step()
        #expect(selects.allowed.isEmpty, "a mount after the limit selected")
    }

    // MARK: cloud new-machine settle (automation)

    /// What `settledCreation` answered, in order.
    @MainActor final class Answers {
        var states: [CreatedMachine?] = []
    }

    private struct CreateFailed: Error {}

    /// Starts `settledCreation` in a task and returns once its limit is armed (the wait started).
    private static func settle(_ creation: CloudMachineCreation, in creations: CloudCreations, rig: WatchRig,
                               into answers: Answers) async -> Task<Void, Never> {
        let work = rig.work, deadlines = rig.deadlines
        // task-owner: the test; it awaits the task's value
        let task = Task { @MainActor in
            let state = await CloudHandlers.settledCreation(creation, in: creations, within: .seconds(30), work: work, deadlines: deadlines)
            answers.states.append(state)
        }
        for _ in 0..<200 where !rig.isArmed { await Task.yield() }
        return task
    }

    @Test func aCreationWaitYieldsToPendingInputThenResumesOnceWhenItSettles() async throws {
        let rig = WatchRig()
        let creations = CloudCreations(work: BackgroundWork(label: "test.first-value-wait"), mainWork: rig.work)
        let creation = creations.begin(window: nil)
        let answers = Answers()
        let task = await Self.settle(creation, in: creations, rig: rig, into: answers)
        #expect(rig.isArmed, "the wait never started")

        rig.input.pending = true
        creation.fail(CreateFailed())
        rig.runTurns()
        for _ in 0..<20 { await Task.yield() }
        #expect(answers.states.isEmpty, "the automation wait ran ahead of the person's pending key")
        #expect(rig.work.postedCount(.automation) == 1, "the settle was not queued as automation")

        rig.input.pending = false
        rig.step()
        await task.value
        #expect(answers.states.count == 1)
        let answer = answers.states.first ?? nil
        guard case .failed? = answer else {
            Issue.record("the wait answered \(String(describing: answer)), not the failure")
            return
        }
        #expect(!rig.isArmed, "the limit stayed armed after the settle")
    }

    @Test func aCreationWaitResumesNilAtItsLimitAndOnlyOnce() async {
        let rig = WatchRig()
        let creations = CloudCreations(work: BackgroundWork(label: "test.first-value-wait"), mainWork: rig.work)
        let creation = creations.begin(window: nil)
        let answers = Answers()
        let task = await Self.settle(creation, in: creations, rig: rig, into: answers)

        rig.fireAndRun()
        await task.value
        #expect(answers.states.count == 1)
        #expect(answers.states.first == .some(nil), "the limit did not answer nil")

        creation.fail(CreateFailed())
        rig.step()
        for _ in 0..<20 { await Task.yield() }
        #expect(answers.states.count == 1, "a settle after the limit answered again")
    }

    @Test func aCreationAlreadySettledAnswersAtOnce() async {
        let rig = WatchRig()
        let creations = CloudCreations(work: BackgroundWork(label: "test.first-value-wait"), mainWork: rig.work)
        let creation = creations.begin(window: nil)
        creations.remove(creation)
        let state = await CloudHandlers.settledCreation(creation, in: creations, within: .seconds(30),
                                                        work: rig.work, deadlines: rig.deadlines)
        #expect(state == .gone)
        #expect(!rig.isArmed)
    }
}

/// A main work scheduler whose budget reads the test's clock and pending-input flag, whose
/// next-turn work queues for ``runTurns()``, and a deadline scheduler on a wake queue the test fires.
@MainActor
private final class WatchRig {
    let work: MainWorkScheduler
    let deadlines: MainDeadlineScheduler
    let input: WatchRigInput
    private let timer: WatchRigTimer
    private let uptime: WatchRigUptime
    private let budgetClock: WatchRigUptime
    private let turns: WatchRigTurns
    private let queue: MainWakeUpQueue
    /// Keeps the display link up, so visible work waits for the test's frames.
    private let keeper: FrameClient
    private var frames: Double = 0

    init() {
        let timer = WatchRigTimer(), uptime = WatchRigUptime(0), budgetClock = WatchRigUptime(1_000_000_000)
        let turns = WatchRigTurns(), input = WatchRigInput()
        self.timer = timer
        self.uptime = uptime
        self.budgetClock = budgetClock
        self.turns = turns
        self.input = input
        let queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in timer }
        let budget = MainFrameBudget(input: input, uptimeNanos: { budgetClock.now })
        let work = MainWorkScheduler.testing(budget: budget, ledger: WakeupLedger(), performTurn: { turns.queued.append($0) }) { _ in
            WatchRigLink()
        }
        self.queue = queue
        self.work = work
        deadlines = MainDeadlineScheduler(work: work, queue: queue)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        self.keeper = keeper
        keeper.activate()
    }

    /// A deadline's wake is armed on the queue.
    var isArmed: Bool { timer.armedDate != nil }

    /// Runs the posted run loop turns, those they queue included.
    func runTurns() {
        while !turns.queued.isEmpty {
            turns.queued.removeFirst()()
        }
    }

    /// The next turns, then one display frame, then the turns it queued.
    func step() {
        runTurns()
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
        runTurns()
    }

    /// Moves the uptime to the armed wake, fires the queue and runs what it posted.
    func fireAndRun() {
        if let date = timer.armedDate { uptime.now = max(uptime.now, date) }
        timer.armedDate = nil
        queue.fire()
        step()
    }
}

/// A person's key waiting for the main thread, as the test sets it.
@MainActor
private final class WatchRigInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// The run loop turns the scheduler asked for, run by the test.
@MainActor
private final class WatchRigTurns {
    var queued: [@MainActor () -> Void] = []
}

/// Keeps the date the queue armed; the test fires the queue itself.
private nonisolated final class WatchRigTimer: MainWakeUpTimer, Sendable {
    private let armed = Mutex<UInt64?>(nil)

    var armedDate: UInt64? {
        get { armed.withLock { $0 } }
        set { armed.withLock { $0 = newValue } }
    }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) { armedDate = date }
    func park() { armedDate = nil }
}

/// A fake clock in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class WatchRigUptime: Sendable {
    private let value: Atomic<UInt64>

    init(_ start: UInt64) {
        value = Atomic(start)
    }

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

private final class WatchRigLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
