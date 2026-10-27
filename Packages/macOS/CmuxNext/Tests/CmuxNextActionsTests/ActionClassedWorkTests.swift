@testable import CmuxNextActions
import CmuxNextWakeups
import Foundation
import Testing

/// ``ActionRegistry/trackWork(owner:on:tracked:file:line:_:then:)`` and ``ActionCompletion``
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, recipe R-hop and rules 2 and 9, group 306): an action's async part
/// runs off main and its main part is one task posted in the run's class with its owner, never an unclassed main-actor
/// continuation. A person's completion is userBlocking and answers their key; an agent's or the CLI's is automation and
/// yields to the person's input; both keep the run's scopes; a capturing caller (the CLI) awaits it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ActionClassedWorkTests {
    private static let catalog = [ActionDescriptor(id: "test.work", title: "Work", category: .other)]
    private static let cli = ActionRunScope(origin: .cli, allowsViewChange: false)

    /// The main part waits for the scheduler: posted in the run's class (`automation` for the CLI), it runs on
    /// the hand-fired frame, on the main thread, and its failure is what the capturing caller gets.
    @Test func theMainPartIsAPostedTaskOfTheRunsClass() async {
        let work = Self.scheduler()
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        let seen = ClassedWorkSeen()
        let tasks = registry.capturingWork {
            ActionRunScope.$current.withValue(Self.cli) {
                _ = registry.trackWork(owner: "test.finish", on: work) { 6 * 7 } then: { result in
                    seen.value = try? result.get()
                    seen.onMain = Thread.isMainThread
                    return "refused: \(seen.value ?? 0)"
                }
            }
        }
        #expect(tasks.count == 1, "the capturing caller did not get the task")
        while work.postedCount(.automation) < 1 { await Task.yield() }
        #expect(seen.value == nil, "the main part ran before its posted task")
        #expect(work.postedCount(.visible) == 0, "a CLI run's main part was posted as visible")
        #expect(work.postedCount(.userBlocking) == 0, "a CLI run's main part took the person's class")
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await tasks[0].value == "refused: 42")
        #expect(seen.value == 42)
        #expect(seen.onMain == true)
        keeper.stop()
    }

    /// A person's run (no run scope: a direct gesture, or `origin: .user`) ends in a `userBlocking` task, never a
    /// visible one; a thrown error reaches the main part as its failure.
    @Test func aPersonsRunEndsUserBlockingAndSeesTheError() async {
        let work = Self.scheduler()
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        let tasks = registry.capturingWork {
            _ = registry.trackWork(owner: "test.fail", on: work) { () throws -> Int in
                throw ClassedWorkFailure.refused
            } then: { result in
                guard case .failure(let error) = result else { return nil }
                return ActionWorkFailure("failed: \(error)")
            }
        }
        while work.postedCount(.userBlocking) < 1 { await Task.yield() }
        #expect(work.postedCount(.visible) == 0, "the person's completion queued behind visible work")
        #expect(work.postedCount(.automation) == 0)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await tasks.first?.value == "failed: refused")
        keeper.stop()
    }

    /// Rule 9, person: the completion of a person's key runs as one userBlocking task under the person's cause on
    /// the next turn (no frame fired), and that task's commit, not the key's own, closes the key's input response.
    @Test func aPersonsCompletionAppliesBeforeTheCommitAndAnswersTheKey() async {
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { 1_000_000_000 }),
                                             performTurn: { turn in Task { @MainActor in turn() } }) { _ in ClassedWorkFakeLink() }
        let registry = ActionRegistry(catalog: Self.catalog)
        let seen = ClassedWorkSeen()
        work.budget.noteDiscreteDispatch(began: true)
        let tasks = registry.capturingWork {
            _ = registry.trackWork(owner: "test.person", on: work) { 1 } then: { _ in
                seen.workClass = work.budget.board.running?.workClass
                seen.cause = work.causes.currentCause
                return nil
            }
        }
        work.budget.noteDiscreteInput(expectsFrame: true)
        work.budget.noteDiscreteDispatch(began: false)
        // The key's own turn commits before its remote half replies.
        work.budget.noteRenderPass(nanos: 1_000_000)
        #expect(work.budget.isInputResponseOpen, "the key's own commit closed its response")
        for task in tasks { #expect(await task.value == nil) }
        #expect(seen.workClass == .userBlocking, "the person's completion ran outside the userBlocking class")
        #expect(seen.cause == .person, "the person's completion lost the person's cause")
        work.budget.noteRenderPass(nanos: 1_000_000)
        #expect(!work.budget.isInputResponseOpen, "the completion's commit did not close the key's response")
    }

    /// Rule 9, automation: a CLI run's completion does not take the turn of a person's key that waits for its frame;
    /// it runs on a later frame.
    @Test func anAutomationCompletionYieldsToThePersonsInput() async {
        let clock = ClassedWorkMovingClock(), turns = ClassedWorkTurns()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: { turns.queue($0) }) { _ in
            ClassedWorkFakeLink()
        }
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        let seen = ClassedWorkSeen()
        let tasks = registry.capturingWork {
            ActionRunScope.$current.withValue(Self.cli) {
                _ = registry.trackWork(owner: "test.agent", on: work) { 42 } then: { result in
                    seen.value = try? result.get()
                    return nil
                }
            }
        }
        while work.postedCount(.automation) < 1 { await Task.yield() }
        // The person presses a key that changes what shows before the agent's completion gets its turn.
        work.noteDiscreteDispatch(began: true)
        work.noteDiscreteInput(expectsFrame: true)
        work.noteDiscreteDispatch(began: false)
        turns.runAll()
        #expect(seen.value == nil, "the agent's completion ran while the person's key waited for its frame")
        var frame = 0.0
        while work.postedCount(.automation) > 0, frame < 60 {
            frame += 1
            clock.advance(17_000_000)
            work.frameDidFire(timestamp: frame, refreshInterval: 1.0 / 60)
        }
        #expect(await tasks[0].value == nil)
        #expect(seen.value == 42, "the agent's completion never ran")
        #expect(frame >= 1, "the agent's completion ran before any frame after the key")
        keeper.stop()
    }

    /// A `.cli` run without `focus`: its completion runs outside the run's task tree, yet sees the run's permission
    /// (no view change) and the App's run locals (the daemon command scope), and so does its off-main part.
    @Test func aCLIRunsCompletionKeepsTheRunsScopes() async {
        let work = Self.scheduler()
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        registry.runLocals = { ClassedWorkLocals(ticket: ClassedWorkLocals.current) }
        let seen = ClassedWorkSeen()
        let tasks = registry.capturingWork {
            ActionRunScope.$current.withValue(Self.cli) {
                ClassedWorkLocals.$current.withValue("ticket-7") {
                    _ = registry.trackWork(owner: "test.scopes", on: work) { () -> String? in
                        ActionRunScope.viewChangeAllowed() ? nil : ClassedWorkLocals.current
                    } then: { result in
                        seen.offMainTicket = try? result.get()
                        seen.viewChangeAllowed = ActionRunScope.viewChangeAllowed()
                        seen.ticket = ClassedWorkLocals.current
                        seen.workClass = work.budget.board.running?.workClass
                        return nil
                    }
                }
            }
        }
        while work.postedCount(.automation) < 1 { await Task.yield() }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await tasks[0].value == nil)
        #expect(seen.viewChangeAllowed == false, "a CLI run without focus changed the view from its completion")
        #expect(seen.ticket == "ticket-7", "the completion lost the run's command scope")
        #expect(seen.offMainTicket == "ticket-7", "the off-main part lost the run's scopes")
        #expect(seen.workClass == .automation)
        keeper.stop()
    }

    /// Untracked work (a move into a new window) still runs its main part but is not handed to the caller.
    @Test func untrackedWorkIsNotCaptured() async {
        let work = Self.scheduler()
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        let seen = ClassedWorkSeen()
        var started: ActionWork?
        let tasks = registry.capturingWork {
            started = registry.trackWork(owner: "test.untracked", on: work, tracked: false) { 1 } then: { _ in
                seen.value = 1
                return nil
            }
        }
        #expect(tasks.isEmpty)
        while work.postedCount(.userBlocking) < 1 { await Task.yield() }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await started?.value == nil)
        #expect(seen.value == 1)
        keeper.stop()
    }

    /// A value-producing run: the answer is made in the posted task and a capturing caller gets it.
    @Test func aResultRunAnswersFromItsPostedTask() async {
        let work = Self.scheduler()
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        let run = registry.capturingRun {
            ActionRunScope.$current.withValue(Self.cli) {
                registry.trackResultWork(owner: "test.result", on: work) { "ws_1" } then: { result in
                    guard case .success(let id) = result else { return .failure("no workspace") }
                    return .success(["workspace_id": .string(id)])
                }
            }
        }
        #expect(run.work.count == 1)
        #expect(run.results.count == 1)
        while work.postedCount(.automation) < 1 { await Task.yield() }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        guard case .success(let fields)? = await run.results.first?.value else {
            Issue.record("no answer")
            keeper.stop()
            return
        }
        #expect(fields["workspace_id"] == .string("ws_1"))
        keeper.stop()
    }

    @Test func theCompletionClassFollowsTheOrigin() {
        let work = Self.scheduler()
        #expect(ActionInvocation(origin: .user).completionClass == .userBlocking)
        #expect(ActionInvocation(origin: .user).completionPriority == .userBlocking)
        for origin in ActionOrigin.allCases where origin != .user {
            #expect(ActionInvocation(origin: origin).completionClass == .automation, "\(origin) competes with the person")
            #expect(ActionInvocation(origin: origin).completionPriority == .userVisible)
        }
        #expect(ActionCompletion(on: work).workClass == .userBlocking, "outside a run: a direct gesture of the person")
        ActionRunScope.$current.withValue(ActionRunScope(origin: .script, allowsViewChange: false)) {
            #expect(ActionCompletion(on: work).workClass == .automation)
            #expect(ActionCompletion(on: work).priority == .userVisible)
        }
    }

    /// A scheduler whose posts run only on hand-fired frames (its turns are never run).
    private static func scheduler() -> MainWorkScheduler {
        let clock = ClassedWorkClock()
        return MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: { _ in }) { _ in
            ClassedWorkFakeLink()
        }
    }
}

private enum ClassedWorkFailure: Error {
    case refused
}

@MainActor
private final class ClassedWorkSeen {
    var value: Int?
    var onMain: Bool?
    var workClass: MainWorkClass?
    var cause: ObservationCause?
    var viewChangeAllowed: Bool?
    var ticket: String?
    var offMainTicket: String?
}

/// A stand-in for the App's daemon command scope: one task local, bound again by an ``ActionCompletion``.
private nonisolated struct ClassedWorkLocals: ActionRunLocals {
    @TaskLocal static var current: String?
    let ticket: String?

    @MainActor func bind<T>(_ body: () -> T) -> T { Self.$current.withValue(ticket, operation: body) }

    func bindAwaiting<T>(_ body: () async -> T) async -> T { await Self.$current.withValue(ticket) { await body() } }
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class ClassedWorkLinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// The turns a scheduler queued, run when the test says.
@MainActor
private final class ClassedWorkTurns {
    private var pending: [@MainActor () -> Void] = []

    func queue(_ turn: @escaping @MainActor () -> Void) { pending.append(turn) }

    func runAll() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

/// A clock the test holds still (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ClassedWorkClock {
    private let now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [now] in now } }
}

/// A clock the test moves by hand.
@MainActor
private final class ClassedWorkMovingClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [unowned self] in self.now } }

    func advance(_ nanos: UInt64) { now += nanos }
}

@MainActor
private final class ClassedWorkFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
