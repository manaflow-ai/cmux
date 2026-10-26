@testable import CmuxNextActions
import CmuxNextWakeups
import QuartzCore
import Testing

/// p06-scheduler-208: the completion of a person's action (the rollback and notice once the remote
/// half of an `.applied` or `.waiting` effect answered) runs as one userBlocking task on the app's
/// main-thread scheduler; a CLI run's completion is not the person's and runs where it resumed.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ActionEffectUserBlockingTests {
    private static let catalog = [ActionDescriptor(id: "test.rename", title: "Rename", category: .other)]

    private final class World {
        var completedIn: [MainWorkClass?] = []
        var onNotice: (() -> Void)?
    }

    private static func rig(_ world: World, wait: Bool) -> (ActionRegistry, MainWorkScheduler) {
        // Each posted turn runs as a main-actor task: no frames, no run loop needed.
        let work = MainWorkScheduler.testing(performTurn: { turn in Task { @MainActor in turn() } }) { _ in UserBlockingTestLink() }
        let registry = ActionRegistry(catalog: catalog)
        registry.mainWork = work
        registry.remoteFailureObserver = { _, _ in world.onNotice?() }
        registry.bindEffect("test.rename", effect: { _ in
            let send: @MainActor () async -> ActionWorkFailure? = { "refused by the daemon" }
            if wait { return .waiting(.daemonEcho, send) }
            return .applied(ActionConfirmation(send: send, rollback: { _ in
                world.completedIn.append(work.budget.board.running?.workClass)
            }))
        })
        return (registry, work)
    }

    @Test func aPersonsRollbackRunsAsUserBlocking() async {
        let world = World()
        let (registry, _) = Self.rig(world, wait: false)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            world.onNotice = { done.resume() }
            registry.perform("test.rename")
        }
        #expect(world.completedIn == [.userBlocking], "the person's rollback ran outside the userBlocking class")
    }

    @Test func aCLIRollbackIsNotUserBlocking() async {
        let world = World()
        let (registry, _) = Self.rig(world, wait: false)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            world.onNotice = { done.resume() }
            registry.perform("test.rename", invocation: ActionInvocation(origin: .cli))
        }
        #expect(world.completedIn == [nil], "an agent's rollback took the person's userBlocking class")
    }

    @Test func aPersonsWaitingCompletionRunsAsUserBlocking() async {
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
}

@MainActor
private final class UserBlockingTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
    func requestFrameRate(_ range: CAFrameRateRange) {}
}
