import CmuxNextActions
import Testing

/// Target-aware reasons: an action can be disabled for one target (the
/// screen's only column) and still run for others; the reason is reported
/// up front, never as an error after the run.
@Suite struct ActionTargetReasonTests {
    @Test func aTargetReasonDisablesThatTargetOnlyAndIsReportedAsTheRefusal() {
        let registry = ActionRegistry.standard()
        var ran = 0
        registry.bind("column.makeSticky", invoke: { _ in ran += 1 })
        ActionTargetReasons.set("column.makeSticky", in: registry) { invocation in
            invocation.target?.id == "lone" ? "Add a second column first" : nil
        }
        let lone = ActionInvocation(target: ActionTargetRef(kind: .column, id: "lone"))
        let other = ActionInvocation(target: ActionTargetRef(kind: .column, id: "c2"))

        #expect(ActionTargetReasons.reason(for: "column.makeSticky", invocation: lone, in: registry) == "Add a second column first")
        #expect(!ActionTargetReasons.canPerform("column.makeSticky", invocation: lone, in: registry))
        #expect(registry.capturingRefusal { registry.perform("column.makeSticky", invocation: lone) } == "Add a second column first")
        #expect(ran == 0)

        #expect(ActionTargetReasons.reason(for: "column.makeSticky", invocation: other, in: registry) == nil)
        #expect(registry.perform("column.makeSticky", invocation: other))
        #expect(ran == 1)
    }

    @Test func rebindingKeepsNoStaleReasonFromAnotherAction() {
        let registry = ActionRegistry.standard()
        ActionTargetReasons.set("column.unstick", in: registry) { _ in "unbound" }
        #expect(!registry.isBound("column.unstick"))
    }
}
