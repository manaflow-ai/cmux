import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextWakeups
import Testing
@testable import CmuxNextApp

/// The person scope ``ActionRouting`` binds (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// "Person cause, app side"), through the real registry run path: a person's run sends in a person
/// scope, and so does a task its handler starts; a CLI, script or page run does not, nor does a run
/// nested in one of them, and a run inside a control-socket scope keeps that scope.
@MainActor @Suite struct PersonCauseRoutingTests {
    @MainActor final class Seen {
        var cause: ObservationCause?
        var taskCause: Task<ObservationCause?, Never>?
    }

    private func make() -> (AppServices, Seen) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        ActionRouting.install(services)
        let seen = Seen()
        services.registry.register(Action(id: "test.cause", title: "test.cause", invoke: { _ in
            seen.cause = DaemonCommandScope.current?.cause
            // task-owner: the test awaits it below
            seen.taskCause = Task { DaemonCommandScope.current?.cause }
        }, handler: {}))
        // A non-person run whose handler performs another action with a default (`user`) invocation.
        services.registry.register(Action(id: "test.nested", title: "test.nested", invoke: { [weak services] _ in
            _ = services?.registry.perform("test.cause", invocation: ActionInvocation())
        }, handler: {}))
        return (services, seen)
    }

    private func run(_ id: ActionID, origin: ActionOrigin) async -> (ObservationCause?, ObservationCause?) {
        let (services, seen) = make()
        #expect(services.registry.perform(id, invocation: ActionInvocation(origin: origin)))
        return (seen.cause, await seen.taskCause?.value)
    }

    @Test func aPersonsRunAndTheTaskItStartsSendAsThePerson() async {
        let (cause, taskCause) = await run("test.cause", origin: .user)
        #expect(cause == .person)
        #expect(taskCause == .person)
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .page, .remote])
    func anAutomationRunGetsNoPersonScope(origin: ActionOrigin) async {
        let (cause, taskCause) = await run("test.cause", origin: origin)
        #expect(cause == nil)
        #expect(taskCause == nil)
    }

    @Test func aDefaultOriginRunNestedInAScriptRunIsNotThePersons() async {
        let (cause, taskCause) = await run("test.nested", origin: .script)
        #expect(cause == nil)
        #expect(taskCause == nil)
    }

    @Test func aRunInsideAControlSocketScopeKeepsItsAutomationScope() async {
        let (services, seen) = make()
        DaemonCommandScope.$current.withValueInTask(DaemonCommandScope.automation(idempotencyKey: nil)) {
            #expect(services.registry.perform("test.cause", invocation: ActionInvocation(origin: .user)))
        }
        #expect(seen.cause == .automation)
        #expect(await seen.taskCause?.value == .automation)
    }
}
