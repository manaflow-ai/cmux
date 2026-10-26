@testable import CmuxNextActions
import CmuxNextWakeups
import Foundation
import Testing

/// ``ActionRegistry/trackWork(_:owner:on:tracked:file:line:_:then:)`` (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// recipe R-hop, group 306): an action's async part runs off main and its main part is one task posted in its class
/// with its owner, never an unclassed main-actor continuation; a capturing caller (the CLI) awaits it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ActionClassedWorkTests {
    private static let catalog = [ActionDescriptor(id: "test.work", title: "Work", category: .other)]

    /// The main part waits for the scheduler: posted in the run's class (`automation` for the CLI), it runs on
    /// the hand-fired frame, on the main thread, and its failure is what the capturing caller gets.
    @Test func theMainPartIsAPostedTaskOfTheRunsClass() async {
        let work = Self.scheduler()
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        let seen = ClassedWorkSeen()
        let invocation = ActionInvocation(origin: .cli)
        let tasks = registry.capturingWork {
            registry.trackWork(invocation.completionClass, owner: "test.finish", on: work) { 6 * 7 } then: { result in
                seen.value = try? result.get()
                seen.onMain = Thread.isMainThread
                return "refused: \(seen.value ?? 0)"
            }
        }
        #expect(tasks.count == 1, "the capturing caller did not get the task")
        while work.postedCount(.automation) < 1 { await Task.yield() }
        #expect(seen.value == nil, "the main part ran before its posted task")
        #expect(work.postedCount(.visible) == 0, "a CLI run's main part was posted as visible")
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await tasks[0].value == "refused: 42")
        #expect(seen.value == 42)
        #expect(seen.onMain == true)
        keeper.stop()
    }

    /// A person's run ends in a `visible` task; a thrown error reaches the main part as its failure.
    @Test func aPersonsRunEndsVisibleAndSeesTheError() async {
        let work = Self.scheduler()
        let keeper = ClassedWorkLinkKeeper(on: work)
        let registry = ActionRegistry(catalog: Self.catalog)
        let invocation = ActionInvocation(origin: .user)
        let tasks = registry.capturingWork {
            registry.trackWork(invocation.completionClass, owner: "test.fail", on: work) { () throws -> Int in
                throw ClassedWorkFailure.refused
            } then: { result in
                guard case .failure(let error) = result else { return nil }
                return ActionWorkFailure("failed: \(error)")
            }
        }
        while work.postedCount(.visible) < 1 { await Task.yield() }
        #expect(work.postedCount(.automation) == 0)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await tasks.first?.value == "failed: refused")
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
            started = registry.trackWork(.visible, owner: "test.untracked", on: work, tracked: false) { 1 } then: { _ in
                seen.value = 1
                return nil
            }
        }
        #expect(tasks.isEmpty)
        while work.postedCount(.visible) < 1 { await Task.yield() }
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
            registry.trackResultWork(.automation, owner: "test.result", on: work) { "ws_1" } then: { result in
                guard case .success(let id) = result else { return .failure("no workspace") }
                return .success(["workspace_id": .string(id)])
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
        #expect(ActionInvocation(origin: .user).completionClass == .visible)
        #expect(ActionInvocation(origin: .user).completionPriority == .userBlocking)
        for origin in ActionOrigin.allCases where origin != .user {
            #expect(ActionInvocation(origin: origin).completionClass == .automation, "\(origin) competes with the person")
            #expect(ActionInvocation(origin: origin).completionPriority == .userVisible)
        }
        #expect(ActionRunScope.completionClass == .visible, "outside a run")
        ActionRunScope.$current.withValue(ActionRunScope(origin: .script, allowsViewChange: false)) {
            #expect(ActionRunScope.completionClass == .automation)
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

/// A clock the test holds still (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ClassedWorkClock {
    private let now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [now] in now } }
}

@MainActor
private final class ClassedWorkFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
