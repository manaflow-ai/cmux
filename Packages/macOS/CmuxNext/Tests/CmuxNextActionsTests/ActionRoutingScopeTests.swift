import CmuxNextActions
import Testing

/// The App routes each invocation to its explicit target's machine by
/// wrapping the handler run (`invocationScope`); an explicit machine
/// target stands in for the focus-derived `cloudWorkspace` context.
@Suite struct ActionRoutingScopeTests {
    @Test func scopeWrapsTheHandlerRunWithTheInvocation() {
        let registry = ActionRegistry.standard()
        var scoped: ActionTargetRef?
        var seenInHandler: ActionTargetRef?
        registry.invocationScope = { invocation, body in
            scoped = invocation.target
            body()
            scoped = nil
        }
        registry.bind("renameWorkspace", invoke: { _ in seenInHandler = scoped })
        let target = ActionTargetRef(kind: .workspace, id: "w-cloud")
        registry.perform("renameWorkspace", invocation: ActionInvocation(target: target, arguments: ["name": .string("x")]))
        #expect(seenInHandler == target)
        #expect(scoped == nil)
    }

    @Test func explicitMachineTargetSatisfiesCloudWorkspace() {
        let registry = ActionRegistry.standard()
        registry.context = [.signedIn]
        var ran = 0
        registry.bind("palette.cloud.status", invoke: { _ in ran += 1 })
        #expect(!registry.perform("palette.cloud.status"))
        #expect(registry.perform("palette.cloud.status", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-1"))))
        #expect(ran == 1)
        #expect(ActionContext.implied(by: ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-1"))) == .cloudWorkspace)
    }
}
