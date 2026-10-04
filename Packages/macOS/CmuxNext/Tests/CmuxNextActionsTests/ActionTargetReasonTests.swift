import CmuxNextActions
import Testing

/// Target-aware reasons: an action can be disabled for one target (the
/// screen's only column) and still run for others; the reason is reported
/// up front, never as an error after the run.
@Suite struct ActionTargetReasonTests {
    @Test func aTargetReasonDisablesThatTargetOnlyAndIsReportedAsTheRefusal() {
        let registry = ActionRegistry.standard()
        var ran = 0
        registry.bind("column.widthHalf", invoke: { _ in ran += 1 })
        ActionTargetReasons.set("column.widthHalf", in: registry) { invocation in
            invocation.target?.id == "lone" ? "Add a second column first" : nil
        }
        let lone = ActionInvocation(target: ActionTargetRef(kind: .column, id: "lone"))
        let other = ActionInvocation(target: ActionTargetRef(kind: .column, id: "c2"))

        #expect(ActionTargetReasons.reason(for: "column.widthHalf", invocation: lone, in: registry) == "Add a second column first")
        #expect(!ActionTargetReasons.canPerform("column.widthHalf", invocation: lone, in: registry))
        #expect(registry.capturingRefusal { registry.perform("column.widthHalf", invocation: lone) } == "Add a second column first")
        #expect(ran == 0)

        #expect(ActionTargetReasons.reason(for: "column.widthHalf", invocation: other, in: registry) == nil)
        #expect(registry.perform("column.widthHalf", invocation: other))
        #expect(ran == 1)
    }

    @Test func rebindingKeepsNoStaleReasonFromAnotherAction() {
        let registry = ActionRegistry.standard()
        ActionTargetReasons.set("column.undock", in: registry) { _ in "unbound" }
        #expect(!registry.isBound("column.undock"))
    }
}

/// Two owners disable one action: the added reason answers first, the
/// earlier one when the added one has nothing to say.
@Suite struct ActionTargetReasonChainTests {
    @Test func anAddedReasonComesFirstAndFallsBackToTheEarlierOne() {
        let registry = ActionRegistry.standard()
        registry.bind("column.moveLeft", invoke: { _ in })
        ActionTargetReasons.set("column.moveLeft", in: registry) { invocation in
            invocation.target?.id == "lone" || invocation.target?.id == "app" ? "Add a second column first" : nil
        }
        ActionTargetReasons.add("column.moveLeft", in: registry) { invocation in
            invocation.target?.id == "app" ? "The app column cannot change" : nil
        }
        func reason(_ id: String) -> String? {
            ActionTargetReasons.reason(for: "column.moveLeft", invocation: ActionInvocation(target: ActionTargetRef(kind: .column, id: id)),
                                       in: registry)
        }
        #expect(reason("app") == "The app column cannot change")
        #expect(reason("lone") == "Add a second column first")
        #expect(reason("c2") == nil)
    }
}
