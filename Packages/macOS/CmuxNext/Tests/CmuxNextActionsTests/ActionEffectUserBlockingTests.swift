@testable import CmuxNextActions
import CmuxNextWakeups
import QuartzCore
import Testing

/// The completion of a person's action (once the remote half of an `.applied`
/// or `.waiting` effect answered: the rollback and notice of a failure, the answer to the person's
/// key on success) runs as one userBlocking task on the app's main-thread scheduler, under the
/// person's cause, and its commit closes the key's input response. A CLI run's completion is not
/// the person's and runs where it resumed, under the CLI's cause.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ActionEffectUserBlockingTests {
    private static let catalog = [ActionDescriptor(id: "test.rename", title: "Rename", category: .other)]

    private final class World {
        var completedIn: [MainWorkClass?] = []
        var rolledBackAs: [ObservationCause] = []
        var onNotice: (() -> Void)?
    }

    /// A scheduler whose posted turns each run as a main-actor task (no frames, no run loop
    /// needed), on a clock that stands still: an input response never reaches its 100 ms cap.
    private static func scheduler() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { 1_000_000_000 }),
                                  performTurn: { turn in Task { @MainActor in turn() } }) { _ in UserBlockingTestLink() }
    }

    private static func rig(_ world: World, wait: Bool, fails: Bool = true) -> (ActionRegistry, MainWorkScheduler) {
        let work = Self.scheduler()
        let registry = ActionRegistry(catalog: catalog)
        registry.mainWork = work
        registry.remoteFailureObserver = { _, _ in world.onNotice?() }
        registry.bindEffect("test.rename", effect: { _ in
            let send: @MainActor () async -> ActionWorkFailure? = { fails ? "refused by the daemon" : nil }
            if wait { return .waiting(.daemonEcho, send) }
            return .applied(ActionConfirmation(send: send, rollback: { _ in
                world.completedIn.append(work.budget.board.running?.workClass)
                world.rolledBackAs.append(work.causes.currentCause)
            }))
        })
        return (registry, work)
    }

    /// The person's key: its dispatch, the action run in it, the frame-expecting input it reports.
    /// Returns the run's work for the test to await.
    private static func keyRunning(_ registry: ActionRegistry, on work: MainWorkScheduler) -> [ActionWork] {
        work.budget.noteDiscreteDispatch(began: true)
        let tasks = registry.capturingWork { registry.perform("test.rename") }
        work.budget.noteDiscreteInput(expectsFrame: true)
        work.budget.noteDiscreteDispatch(began: false)
        return tasks
    }

    @Test func aPersonsRollbackRunsAsUserBlockingUnderThePersonsCause() async {
        let world = World()
        let (registry, _) = Self.rig(world, wait: false)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            world.onNotice = { done.resume() }
            registry.perform("test.rename")
        }
        #expect(world.completedIn == [.userBlocking], "the person's rollback ran outside the userBlocking class")
        #expect(world.rolledBackAs == [.person], "the rollback's model changes lost the person's cause")
    }

    @Test func aCLIRollbackIsNotUserBlocking() async {
        let world = World()
        let (registry, _) = Self.rig(world, wait: false)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            world.onNotice = { done.resume() }
            registry.perform("test.rename", invocation: ActionInvocation(origin: .cli))
        }
        #expect(world.completedIn == [nil], "an agent's rollback took the person's userBlocking class")
        #expect(world.rolledBackAs == [.automation], "an agent's rollback did not run as automation")
    }

    @Test func aPersonsWaitingFailureNoticeRunsAsUserBlocking() async {
        let world = World()
        let (registry, work) = Self.rig(world, wait: true)
        var noticeClass: MainWorkClass?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            world.onNotice = {
                noticeClass = work.budget.board.running?.workClass
                done.resume()
            }
            registry.perform("test.rename")
        }
        #expect(noticeClass == .userBlocking, "the waiting action's failure notice ran outside the userBlocking class")
        #expect(work.budget.stats.tasks[3] == 1)
    }

    /// A successful `.waiting` run started by a person's key (Cmd-T, Cmd-N): its completion is one
    /// userBlocking task, and that task's commit, not the key's own, closes the key's response.
    @Test func aPersonsSuccessfulWaitingCompletionRunsAsUserBlockingAndItsCommitClosesTheResponse() async {
        let world = World()
        let (registry, work) = Self.rig(world, wait: true, fails: false)
        let tasks = Self.keyRunning(registry, on: work)
        #expect(tasks.count == 1)
        // The key's own turn commits before its remote half replies.
        work.budget.noteRenderPass(nanos: 1_000_000)
        #expect(work.budget.isInputResponseOpen, "the key's own commit closed its response")
        for task in tasks { #expect(await task.value == nil) }
        #expect(work.budget.stats.tasks[3] == 1, "the person's completion did not run as one userBlocking task")
        #expect(work.budget.isInputResponseOpen, "the completion has not committed yet")
        work.budget.noteRenderPass(nanos: 1_000_000)
        #expect(!work.budget.isInputResponseOpen, "the completion's commit did not close the key's response")
    }

    /// A successful run that answers no key (a person's run outside a dispatch) has nothing left
    /// to do on main: no task.
    @Test func aSuccessfulRunThatAnswersNoKeyPostsNothing() async {
        let world = World()
        let (registry, work) = Self.rig(world, wait: true, fails: false)
        let tasks = registry.capturingWork { registry.perform("test.rename") }
        for task in tasks { #expect(await task.value == nil) }
        #expect(work.budget.stats.tasks[3] == 0)
        #expect(world.completedIn.isEmpty)
    }

    /// A person-scope reply (a daemon command an action run of the person sent,
    /// `DaemonService.settleReply`) settles as one userBlocking task under the person's cause; an
    /// agent's runs where it resumed, under the agent's cause.
    @Test func aPersonScopeReplyRunsAsUserBlockingUnderThePersonsCause() async {
        let work = Self.scheduler()
        var classes: [MainWorkClass?] = []
        var causes: [ObservationCause] = []
        for origin in [ActionOrigin.user, .cli] {
            await ActionRunScope.$current.withValue(ActionRunScope(origin: origin, allowsViewChange: false)) {
                let cause = ActionRunScope.current?.origin.observationCause ?? .program
                await work.reply(as: cause, owner: "test.reply") {
                    classes.append(work.budget.board.running?.workClass)
                    causes.append(work.causes.currentCause)
                }
            }
        }
        #expect(classes == [.userBlocking, nil], "the person's reply ran outside the userBlocking class")
        #expect(causes == [.person, .automation])
    }
}

@MainActor
private final class UserBlockingTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
    func requestFrameRate(_ range: CAFrameRateRange) {}
}
