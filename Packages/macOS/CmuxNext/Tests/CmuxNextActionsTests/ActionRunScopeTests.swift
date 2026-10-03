@testable import CmuxNextActions
import Testing

/// The view-change permission travels with the run as a task local
/// (`ActionRunScope`): the registry binds it for the handler and every task
/// the handler starts, from the invocation's origin, its `focus` request and
/// the descriptor's `focuses`; a run started inside another never gains a
/// permission the outer run lacks.
@MainActor
@Suite struct ActionRunScopeTests {
    @Test func outsideAnyRunTheViewMayChange() {
        #expect(ActionRunScope.current == nil)
        #expect(ActionRunScope.viewChangeAllowed())
    }

    @Test func theRegistryBindsTheRunsPermissionForTheHandlerAndItsTasks() async {
        let registry = ActionRegistry.standard()
        var seen: [Bool] = []
        var tasks: [Task<Bool, Never>] = []
        registry.bind("splitRight", invoke: { _ in
            seen.append(ActionRunScope.viewChangeAllowed())
            tasks.append(Task { await Task.yield(); return ActionRunScope.viewChangeAllowed() })
        })
        registry.bind("tab.focus", invoke: { _ in seen.append(ActionRunScope.viewChangeAllowed()) })
        registry.perform("splitRight", invocation: ActionInvocation(origin: .cli))
        registry.perform("splitRight", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        registry.perform("splitRight", invocation: ActionInvocation(arguments: ["focus": .bool(true)], origin: .mcp))
        registry.perform("splitRight", invocation: ActionInvocation())
        registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: "t"), origin: .cli))
        #expect(seen == [false, true, true, true, true])
        var later: [Bool] = []
        for task in tasks { later.append(await task.value) }
        #expect(later == [false, true, true, true])
        #expect(ActionRunScope.viewChangeAllowed())
    }

    @Test func aRunInsideAnotherNeverGainsPermission() {
        let registry = ActionRegistry.standard()
        var inner: [Bool] = []
        registry.bind("tab.focus", invoke: { _ in inner.append(ActionRunScope.viewChangeAllowed()) })
        registry.bind("splitRight", invoke: { _ in
            // A handler running another action with a default (user) invocation.
            registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: "t")))
        })
        registry.perform("splitRight", invocation: ActionInvocation(origin: .cli))
        registry.perform("splitRight", invocation: ActionInvocation())
        #expect(inner == [false, true])
    }

    @Test func aCarriedScopeKeepsItsPermissionOutsideTheRun() {
        let scope = ActionRunScope(origin: .script, allowsViewChange: false)
        #expect(ActionRunScope.carrying(scope) { ActionRunScope.viewChangeAllowed() } == false)
        #expect(ActionRunScope.carrying(nil) { ActionRunScope.viewChangeAllowed() })
    }
}
