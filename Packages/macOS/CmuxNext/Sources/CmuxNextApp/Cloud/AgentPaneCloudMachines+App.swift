import CmuxNextActions
import CmuxNextAgentPane

extension AgentPaneCloudMachines {
    /// How old the App's machine list may be when a picker reads it: an open picker reads every
    /// few seconds, the server's list at most this often (the store also follows each machine's
    /// own link between reads).
    static let listAge: Duration = .seconds(60)

    /// The App's answers to `cloudMachine.*`: the machines of the account signed in now
    /// (``CloudService``, never another user's or team's list), and Open Machine and Resume
    /// Machine on one of them, run as the person's own.
    func wire(_ services: AppServices) {
        list = { [weak services] in
            guard let services, services.cloud.isSignedIn else { return Inventory(signedIn: false, loaded: false, machines: []) }
            await services.cloud.refresh(ifOlderThan: Self.listAge)
            guard services.cloud.isSignedIn, services.cloud.hasLoadedCurrentMachines else {
                return Inventory(signedIn: services.cloud.isSignedIn, loaded: false, machines: [])
            }
            let machines = services.machines.cloud.compactMap { session in
                session.effectiveStatus == .destroyed ? nil : Machine(id: session.machineID, name: session.machine.title, stage: session.stage.name)
            }
            return Inventory(signedIn: true, loaded: true, machines: machines)
        }
        open = { [weak services] id in
            services.map { Self.perform("cloudOpenMachine", on: id, services: $0) { _ in true } } ?? false
        }
        resume = { [weak services] id in
            services.map { Self.perform("cloudResumeMachine", on: id, services: $0) { $0.effectiveStatus == .paused } } ?? false
        }
    }

    /// Runs `action` on machine `id` when it is one of the loaded list's and `allowed`; false otherwise.
    /// `machines.cloud` is the list ``CloudService/refresh()`` reconciled for the account signed in
    /// now (``CloudService/hasLoadedCurrentMachines``): the same rows `cloudMachine.list` answered.
    private static func perform(_ action: ActionID, on id: String, services: AppServices, allowed: (CloudMachineSession) -> Bool) -> Bool {
        guard services.cloud.isSignedIn, services.cloud.hasLoadedCurrentMachines,
              let session = services.machines.cloud.first(where: { $0.machineID == id }),
              session.effectiveStatus != .destroyed, allowed(session) else { return false }
        return services.registry.perform(action, invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: id), origin: .user))
    }
}
