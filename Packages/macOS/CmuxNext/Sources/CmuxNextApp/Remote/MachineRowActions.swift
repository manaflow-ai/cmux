import AppKit
import CmuxNextActions
public import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextServer

extension AcpmuxPersonLine: JoinedDialLine {}

/// The machine rows' actions: New Workspace on a joined Mac over the hub (the hosts sidebar's
/// `openJoined`), and a joined machine's Check, Rotate Credential and Revoke… in the registry.
@MainActor enum MachineRowActions {
    /// New Workspace on a joined Mac reached through the hub alone, over the app's acpmux, servers and registry.
    static func signedInDial(_ services: AppServices) -> SignedInMachineDial {
        SignedInMachineDial(
            line: { [weak services] in
                guard let services, let environment = QuitAgents.environment(services) else { return nil }
                return await AcpmuxPersonLine.open(environment, deadline: .seconds(30))
            },
            openRoute: { [weak services] in services?.serverReach.openSignedIn($0, joined: $1) ?? false },
            isConnected: { [weak services] id in
                guard let daemon = services?.machines.daemon(machine: id) else { return nil }
                if case .connected = daemon.store.connectionState { return true }
                return false
            },
            newWorkspace: { [weak services] in
                services?.registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string($0)])) ?? false
            })
    }

    /// A joined machine's menu item. Revoke asks first; Rotate and Revoke read the list again after.
    static func perform(_ action: JoinedMachineAction, _ machine: JoinedMachine, rowID: String, services: AppServices) {
        let window = services.windows.active?.window
        switch action {
        case .check:
            services.addMachine.checkJoined(id: machine.id, name: machine.name, rowID: rowID, over: window)
        case .rotate:
            // task-owner: one rotate; ends with its list read.
            Task { await services.joinedMachines.perform(.rotate, machine.id) }
        case .revoke:
            let asked = JoinedMachineAction.revokePrompt(machine.name)
            let prompt = DestructiveConfirmation.Prompt(title: asked.title, body: asked.body, button: asked.button)
            DestructiveConfirmation.present(prompt, in: window, settings: services.settings) { confirmed in
                guard confirmed else { return }
                // task-owner: one revoke; ends with its list read.
                Task { await services.joinedMachines.perform(.revoke, machine.id) }
            }
        }
    }

    /// The registered action of a joined machine's menu row (`JoinedMachineActionCatalog`).
    static func actionID(_ action: JoinedMachineAction) -> ActionID { ActionID(rawValue: "machine.joined.\(action.rawValue)") }

    /// A joined machine's "…" menu: the registry's rows for it, run on its id with the row it opened
    /// on (`row`, where Check records its result).
    static func joinedMenu(_ machine: JoinedMachine, rowID: String, registry: ActionRegistry) -> NSMenu {
        registry.makeContextMenu(for: .joinedMachine, target: ActionTargetRef(kind: .machine, id: machine.id),
                                 arguments: ["row": .string(rowID)])
    }

    static func bindJoinedActions(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        bindJoinedActions(into: registry, store: { [weak services] in services?.joinedMachines },
                          labsOn: { true },
                          perform: { [weak services] action, machine, rowID in
                              guard let services else { return }
                              Self.perform(action, machine, rowID: rowID, services: services)
                          })
    }

    /// Binds Check, Rotate Credential and Revoke… on a joined machine (a `machine:` target that is a
    /// joined machine's id). They do nothing while `labsOn` says no (the app's is always on). A revoked
    /// machine's menu leaves out Rotate and Revoke; while a change runs on it they wait.
    static func bindJoinedActions(into registry: ActionRegistry, store: @escaping @MainActor () -> JoinedMachineStore?,
                                  labsOn: @escaping @MainActor () -> Bool,
                                  perform: @escaping @MainActor (JoinedMachineAction, JoinedMachine, String) -> Void) {
        let joined: @MainActor (ActionInvocation) -> JoinedMachine? = { invocation in
            guard let id = invocation.target?.id else { return nil }
            return store()?.machines.first { $0.id == id }
        }
        for action in JoinedMachineAction.allCases {
            let id = actionID(action)
            // Check opens its checklist and Revoke its question on this turn; Rotate starts at once.
            // The platform's answers come later, through the store (the row's spinner and caption).
            registry.bindEffect(id, unavailable: { labsOn() ? nil : JoinedMachineAction.labsOff }, effect: { invocation in
                guard let machine = joined(invocation) else {
                    return .refused(RemoteStrings.unknownMachine(invocation.target?.id ?? ""))
                }
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
