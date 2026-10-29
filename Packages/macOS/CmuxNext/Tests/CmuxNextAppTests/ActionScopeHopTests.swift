import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Work an action starts off main keeps the action's scopes (R-hop). A
/// `BackgroundWork.task` is detached and inherits no task local, and the main steps it posts run
/// outside any task tree, so the personal group commit and the incognito create carry the caller's
/// ``DaemonCommandScope`` and ``ActionRunScope`` across the hop: `action.run` waits for what they
/// send, a retry with the same key replays it, and a person's echo keeps its cause.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ActionScopeHopTests {
    /// What the commit's step after the reply saw.
    @MainActor final class Seen {
        var done = false
        var command: DaemonCommandScope?
        var run: ActionRunScope?
    }

    /// Runs one personal group commit inside `scope` and `run`, on a home daemon that is not
    /// connected: the command fails, and its failure step runs on a frame.
    private func commit(in scope: DaemonCommandScope, run: ActionRunScope) async -> Seen {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let life = PersonalGroupLife(services: services), seen = Seen()
        DaemonCommandScope.$current.withValueInTask(scope) {
            ActionRunScope.$current.withValueInTask(run) {
                life.commit("test.commit", ending: [], failed: {
                    seen.command = DaemonCommandScope.current
                    seen.run = ActionRunScope.current
                    seen.done = true
                }) { _ -> Void in }
            }
        }
        while !seen.done {
            rig.frame()
            await Task.yield()
        }
        withExtendedLifetime(services) {}
        return seen
    }

    @Test func aCommitInAControlSocketScopeSendsAndSettlesInThatScope() async {
        let scope = DaemonCommandScope.automation(idempotencyKey: "personal-commit")
        let run = ActionRunScope(origin: .cli, allowsViewChange: false)
        let seen = await commit(in: scope, run: run)
        #expect(scope.ticketCount == 1, "the command opened no ticket in the action's scope: action.run answers before it")
        #expect(scope.failures.map(\.label) == ["test.commit"], "the command's failure did not reach the action's scope")
        #expect(seen.command === scope, "the step after the reply ran outside the action's daemon scope")
        #expect(seen.run == run, "the step after the reply lost the run's view-change permission")
    }

    @Test func aPersonsCommitKeepsThePersonScopeAfterItsReply() async {
        let scope = DaemonCommandScope.person(clock: ContinuousClock(), lifespan: .seconds(60))
        let run = ActionRunScope(origin: .user, allowsViewChange: true)
        let seen = await commit(in: scope, run: run)
        #expect(seen.command === scope)
        #expect(seen.command?.cause == .person, "the person's echo would apply outside the input-response pass")
        #expect(seen.run == run)
    }
}

/// The incognito create on a same-tree daemon, made inside a control-socket scope with an
/// idempotency key.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct IncognitoActionScopeTests {
    @Test func anIncognitoWindowMadeInAnActionScopeCreatesItsWorkspaceInThatScope() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let windows = services.windows
            try #require(EphemeralWorkspaces.localDaemonServes(windows), "the same-tree daemon serves state resources")
            let key = "incognito-scope-\(UUID().uuidString)"
            let scope = DaemonCommandScope.automation(idempotencyKey: key)
            let window = DaemonCommandScope.$current.withValueInTask(scope) { windows.newIncognitoWindow() }
            try await PasswordManagerRouteTests.until({ !windows.pendingEphemeralWindows.contains(window) }, within: .seconds(30))
            // The create took the scope's first derived mutation id, the one a retry with the key sends
            // again; a fresh scope with the key derives that same id next.
            #expect(scope.nextMutationID() != DaemonCommandScope.automation(idempotencyKey: key).nextMutationID(),
                    "the incognito create sent a random mutation id outside the action's scope")
        }
    }
}
