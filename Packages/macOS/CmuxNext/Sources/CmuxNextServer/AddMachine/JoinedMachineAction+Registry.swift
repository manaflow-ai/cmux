public import AppKit
public import CmuxNextActions

/// A joined machine's registered actions (`JoinedMachineActionCatalog`): their ids, the row's "…"
/// menu and their binding on the store. The App says what each one does (`perform`) and how a
/// machine the store does not list is refused.
extension JoinedMachineAction {
    /// The registered action of a joined machine's menu row.
    public nonisolated var actionID: ActionID { ActionID(rawValue: "machine.joined.\(rawValue)") }

    /// The palette rows (`cmux machine|device rotate|revoke`); Check stays the row's, where it records its result.
    public nonisolated static var paletteActions: Set<ActionID> { [Self.rotate.actionID, Self.revoke.actionID] }

    /// The joined machine a run names: the palette's pick (`machine`), else the menu row's target.
    public nonisolated static func machineID(_ invocation: ActionInvocation) -> String? {
        invocation["machine"]?.targetValue?.id ?? invocation.target?.id
    }

    /// A joined machine's "…" menu: the registry's rows for it, run on its id with the row it opened
    /// on (`row`, where Check records its result).
    @MainActor public static func menu(_ machine: JoinedMachine, rowID: String, registry: ActionRegistry) -> NSMenu {
        registry.makeContextMenu(for: .joinedMachine, target: ActionTargetRef(kind: .machine, id: machine.id),
                                 arguments: ["row": .string(rowID)])
    }

    /// Binds Check, Rotate Credential and Revoke… on a joined machine (a `machine:` target that is a
    /// joined machine's id, or the palette's pick). They do nothing while `labsOn` says no (the app's is
    /// always on). A revoked machine's menu leaves out Rotate and Revoke; while a change runs on it they wait.
    @MainActor public static func bind(into registry: ActionRegistry, store: @escaping @MainActor () -> JoinedMachineStore?,
                            labsOn: @escaping @MainActor () -> Bool, unknown: @escaping @MainActor (String) -> String,
                            perform: @escaping @MainActor (JoinedMachineAction, JoinedMachine, String) -> Void) {
        let joined: @MainActor (ActionInvocation) -> JoinedMachine? = { invocation in
            guard let id = machineID(invocation) else { return nil }
            return store()?.machines.first { $0.id == id }
        }
        for action in JoinedMachineAction.allCases {
            let id = action.actionID
            // Check opens its checklist and Revoke its question on this turn; Rotate starts at once.
            // The platform's answers come later, through the store (the row's spinner and caption).
            registry.bindEffect(id, unavailable: { labsOn() ? nil : JoinedMachineAction.labsOff }, effect: { invocation in
                guard let machine = joined(invocation) else { return .refused(unknown(machineID(invocation) ?? "")) }
                perform(action, machine, invocation["row"]?.stringValue ?? JoinedMachine.healthID(machine.id))
                return .done
            })
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                guard let machine = joined(invocation) else { return true }
                return !action.isAvailable(for: machine.state)
            }
            guard action != .check else { continue }
            ActionTargetReasons.set(id, in: registry) { invocation in
                guard let machine = joined(invocation), store()?.busy.contains(machine.id) == true else { return nil }
                return JoinedMachineAction.busy
            }
        }
    }
}
