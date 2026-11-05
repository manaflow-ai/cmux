import CmuxNextActions
import CmuxNextCloud

// Open Desktop's gate: a machine that reports no desktop never offers it.
extension CloudHandlers {
    static let openDesktopAction: ActionID = "cloudOpenDesktop"

    /// Why Open Desktop cannot run on `machine`, or nil: refused unless the machine's
    /// capabilities declare `desktop` (a record that declares none, from an older server or a
    /// classic machine, keeps its noVNC viewer, as ``CloudMachine/allows(_:)`` says).
    static func desktopUnavailableReason(_ machine: CloudMachine) -> String? {
        machine.allows(.desktop) ? nil : CloudStrings.desktopUnavailable(machine.title)
    }

    /// Open Desktop on a machine without a desktop: left out of its context menu, its palette
    /// row disabled with the reason, and every run (CLI, MCP, keyboard) refused with it. A
    /// lookup that names no machine leaves the action's own refusal to the run.
    @MainActor static func gateOpenDesktop(into registry: ActionRegistry, context: AppActionContext) {
        let id = openDesktopAction
        let reason: @MainActor (ActionInvocation) -> String? = { invocation in
            (try? machine(invocation, context)).flatMap { desktopUnavailableReason($0.machine) }
        }
        let earlier = registry.action(for: id)?.targetUnavailableReason
        context.setTargetReason(id) { invocation in reason(invocation) ?? earlier?(invocation) }
        ActionTargetVisibility.hide(id, in: registry) { invocation in reason(invocation) != nil }
        ActionTargetTitles.setPaletteReason(id, in: registry) { [weak registry] in
            registry?.withoutRefusals { reason(ActionInvocation()) }
        }
    }
}
