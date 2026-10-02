import CmuxNextActions
import Testing

/// Destructive actions declare `destructive` and take a typed `confirm`
/// argument. Keyboard, menu, and palette runs ask the confirmation
/// presenter first; a scripted run (control socket) must pass
/// `confirm: true` or is refused with a typed reason.
@Suite struct DestructiveActionTests {
    static let destructiveIDs: [ActionID] = [
        "cloudKillMachine", "palette.cloud.deleteSnapshot", "workspaceGroup.delete", "workspaceGroup.closeWorkspaces", "closeWorkspace", "tabGroup.close",
    ]

    @Test func catalogDeclaresDestructiveActionsWithConfirmArgument() throws {
        let registry = ActionRegistry.standard()
        for id in Self.destructiveIDs {
            let descriptor = try #require(registry.descriptor(for: id))
            #expect(descriptor.isDestructive, "\(id) must be destructive")
            let confirm = try #require(descriptor.arguments.first { $0.name == "confirm" }, "\(id) needs a confirm argument")
            #expect(confirm.kind == .bool)
            #expect(!confirm.isRequired)
        }
        #expect(registry.descriptor(for: "renameWorkspace")?.isDestructive == false)
        #expect(registry.descriptor(for: "renameWorkspace")?.arguments.contains { $0.name == "confirm" } == false)
    }

    @Test func interactiveRunAsksThePresenterThenRunsConfirmed() {
        let registry = ActionRegistry.standard()
        var runs: [ActionInvocation] = []
        registry.bind("workspaceGroup.delete", invoke: { runs.append($0) })
        var asked: [ActionID] = []
        var proceed: (() -> Void)?
        registry.confirmationPresenter = { id, _, go in
            asked.append(id)
            proceed = go
        }

        let target = ActionTargetRef(kind: .workspaceGroup, id: "g1")
        #expect(registry.perform("workspaceGroup.delete", invocation: ActionInvocation(target: target)))
        #expect(asked == ["workspaceGroup.delete"])
        #expect(runs.isEmpty)

        proceed?()
        #expect(runs.count == 1)
        #expect(runs.first?.target == target)
        #expect(runs.first?.isConfirmed == true)
    }

    @Test func confirmedInvocationSkipsThePresenter() {
        let registry = ActionRegistry.standard()
        var ran = 0
        registry.bind("cloudKillMachine", invoke: { _ in ran += 1 })
        registry.confirmationPresenter = { _, _, _ in Issue.record("must not ask when confirmed") }
        #expect(registry.perform("cloudKillMachine", invocation: ActionInvocation(arguments: ["confirm": .bool(true)])))
        #expect(ran == 1)
    }

    @Test func scriptedRunWithoutConfirmIsRefusedWithTypedReason() {
        let registry = ActionRegistry.standard()
        var ran = 0
        registry.bind("tabGroup.close", invoke: { _ in ran += 1 })
        registry.confirmationPresenter = { _, _, _ in Issue.record("a scripted run cannot answer a sheet") }

        let reason = registry.capturingRefusal { registry.perform("tabGroup.close") }
        #expect(ran == 0)
        #expect(reason == ActionRegistry.confirmationRequiredReason(for: "tabGroup.close"))
        #expect(reason?.contains("confirm") == true)

        let confirmed = registry.capturingRefusal {
            registry.perform("tabGroup.close", invocation: ActionInvocation(arguments: ["confirm": .bool(true)]))
        }
        #expect(confirmed == nil)
        #expect(ran == 1)
    }

    @Test func noPresenterRefusesInsteadOfRunning() {
        let registry = ActionRegistry.standard()
        var ran = 0
        var refusals: [String] = []
        registry.refusalObserver = { refusals.append($0) }
        registry.bind("closeWorkspace", invoke: { _ in ran += 1 })
        registry.perform("closeWorkspace")
        #expect(ran == 0)
        #expect(refusals == [ActionRegistry.confirmationRequiredReason(for: "closeWorkspace")])
    }
}
