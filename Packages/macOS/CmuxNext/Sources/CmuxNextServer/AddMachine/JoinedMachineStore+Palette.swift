public import CmuxNextActions
public import CmuxNextPalette

/// The palette's pick for Check, Rotate Credential and Revoke… on a joined machine: a machine joined
/// through the hub, not a connected one (`paletteTargetSource` `joined` in the action catalog,
/// cmux-action-catalog joined_machine.rs). The pick is the invocation's target, as the row's "…"
/// menu passes it, so the same binding runs both.
extension JoinedMachineStore {
    /// A source for each of `descriptors` whose `paletteTargetSource` is `joined`, before `next`: it
    /// lists the joined machines the action can run on, the last rows first, then a fresh read.
    public func paletteTargets(_ descriptors: [ActionDescriptor], next: any PaletteTargetSource) -> any PaletteTargetSource {
        let joined = Set(descriptors.filter { $0.paletteTargetSource == "joined" }.map(\.id))
        return JoinedMachineAction.allCases.reduce(next) { next, action in
            let id = ActionID(rawValue: "machine.joined.\(action.rawValue)")
            guard joined.contains(id) else { return next }
            return RefreshingPaletteTargetSource(kind: .machine, actions: [id], initial: paletteOptions(for: action), next: next) { [weak self] in
                guard let self else { return [] }
                await refresh()
                return paletteOptions(for: action)
            }
        }
    }

    /// Each joined machine `action` can run on (a revoked one only for Check), by name.
    public func paletteOptions(for action: JoinedMachineAction) -> [PaletteTargetOption] {
        machines.filter { action.isAvailable(for: $0.state) }
            .map { PaletteTargetOption(id: $0.id, title: $0.name, subtitle: $0.hostname, symbol: "server.rack") }
    }
}
