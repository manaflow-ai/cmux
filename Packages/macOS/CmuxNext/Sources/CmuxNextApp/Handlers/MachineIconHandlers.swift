import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Set and remove a machine's icon (`session-icon-v1`, cx-qno.11.4): the
/// shared icon string, kept on the machine's record in the home daemon's
/// session registry. An icon argument (CLI, MCP, scripts) sets it; without
/// one (the palette, a machine header's menu) the shared icon picker opens
/// beside the machine's sidebar header and its pick takes the same path.
/// Every change goes through `IconHistory`, so a user's change offers an
/// undo. The home daemon takes every change and stores an image or SVG pick.
enum MachineIconHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let services = ctx.services, capability = DaemonCapability.sessionIcon.rawValue
        registry.bind("machine.setIcon", requires: capability, daemon: services.machines.local, run: { invocation in
            let machine = try machineID(invocation, services)
            let history = IconHistory.machine(ctx), current = services.machines.icon(machine: machine)
            if let icon = try GroupIconArgument.icon(in: invocation) {
                return try history.change(machine, from: current, to: icon, origin: invocation.origin)
            }
            guard let anchor = services.iconPicker.anchor(machine: machine) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
            }
            services.iconPicker.pick(current: current, target: "machine:\(machine)", at: anchor,
                                     assets: IconAssetStore.owner(services.machines.local)) { result in
                // Read the icon the machine shows when the pick lands.
                let shown = services.machines.icon(machine: machine)
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon, assets: true):
                    try? history.change(machine, from: shown, to: icon, origin: .user)
                case .clear: try? history.change(machine, from: shown, to: nil, origin: .user)
                case .set, .cancel: break
                }
            }
        })
        registry.bind("machine.clearIcon", requires: capability, daemon: services.machines.local, run: { invocation in
            let machine = try machineID(invocation, services)
            try IconHistory.machine(ctx).change(machine, from: services.machines.icon(machine: machine), to: nil, origin: invocation.origin)
        })
        // A header's menu leaves Remove Icon out while its machine has none
        // (quiet: building a menu never refuses).
        ActionTargetVisibility.hide("machine.clearIcon", in: registry) { invocation in
            guard let target = invocation.target, target.kind == .machine else { return false }
            return (services.machines.icon(machine: target.id) ?? "").isEmpty
        }
    }

    /// The machine an invocation names: the right-clicked header's (or
    /// `--target machine:<id>`), else the active window's machine. Refused
    /// until the home registry records the machine (`set-session-icon`
    /// answers `unknown session` before `put-session` lands).
    static func machineID(_ invocation: ActionInvocation, _ services: AppServices) throws -> String {
        let machines = services.machines
        let id: String
        if let target = invocation.target, target.kind == .machine {
            guard machines.anyDaemon(machine: target.id) != nil else {
                throw ActionFailure.notFound(RefusalStrings.notShownInAnyWindow(target.description))
            }
            id = target.id
        } else {
            id = services.windows.active?.state.machineID ?? MachineRegistry.localID
        }
        guard let session = machines.sessionID(machine: id) else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.machineNotConnected) }
        guard machines.local.store.personal.session(session) != nil else { throw ActionFailure.invalidTarget(RefusalStrings.machineIconNotRegistered) }
        return id
    }
}

extension IconHistory {
    /// A machine, by its machine id: the change goes to the home daemon's
    /// session registry under the session id the machine is recorded as.
    static func machine(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            let machines = ctx.services.machines, home = machines.local
            guard let session = machines.sessionID(machine: id) else { return false }
            guard home.supports(DaemonCapability.sessionIcon.rawValue) else {
                throw ActionFailure(message: home.missingCapabilityMessage(DaemonCapability.sessionIcon.rawValue))
            }
            let icon: String?
            switch update {
            case .unchanged: return true
            case .clear: icon = nil
            case .set(let value): icon = value
            }
            home.send("set-session-icon") { _ = try await $0.request(SetSessionIconRequest(sessionID: session, icon: icon)) }
            return true
        }
    }
}
