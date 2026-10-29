import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud

extension AgentPaneCloudMachines {
    /// How old the App's machine list may be when a picker reads it: an open picker reads every
    /// few seconds, the server's list at most this often (the store also follows each machine's
    /// own link between reads).
    static let listAge: Duration = .seconds(60)

    /// The App's answers to `cloudMachine.*`: the machines of the account signed in now
    /// (``CloudService``, never another user's or team's list), and Open Machine and Resume
    /// Machine on one of them, run as the person's own.
    func wire(_ services: AppServices) {
        let inventory: @MainActor (Duration) async -> Inventory = { [weak services] age in
            guard let services, services.cloud.isSignedIn else { return Inventory(signedIn: false, loaded: false, machines: []) }
            // Complete only when this read's own refresh landed (the recovery list), or the store
            // holds a server answer within `age` (the picker): a superseded or failed refresh leaves
            // the earlier registry in place, and a machine absent from it may still exist.
            let complete = age == .zero ? await services.cloud.refresh() : await services.cloud.refresh(ifOlderThan: age)
            guard services.cloud.isSignedIn, services.cloud.hasLoadedCurrentMachines,
                  age != .zero || (services.cloud.lastError == nil && services.cloud.unavailableReason == nil) else {
                return Inventory(signedIn: services.cloud.isSignedIn, loaded: false, machines: [])
            }
            let machines = services.machines.cloud.compactMap { session in
                session.effectiveStatus == .destroyed ? nil : Machine(id: session.machineID, name: session.machine.title, stage: session.stage.name)
            }
            return Inventory(signedIn: true, loaded: true, machines: machines, account: services.cloud.account, complete: complete)
        }
        list = { await inventory(Self.listAge) }
        recoveryList = { await inventory(.zero) }
        attach = { [weak services] id in
            guard let services else { return false }
            return await Self.recoveryAttach(
                refresh: { services.cloud.isSignedIn ? await services.cloud.refresh() : false },
                machine: {
                    guard services.cloud.isSignedIn, services.cloud.hasLoadedCurrentMachines,
                          let session = services.machines.session(id) else { return nil }
                    return (session.effectiveStatus, session.stageInput.daemonConnected)
                },
                resume: { services.machines.session(id)?.attach(origin: .user) },
                connect: { services.machines.session(id)?.retryNow() }
            )
        }
        open = { [weak services] id in
            services.map { Self.perform("cloudOpenMachine", on: id, services: $0) { _ in true } } ?? false
        }
        resume = { [weak services] id in
            services.map { Self.perform("cloudResumeMachine", on: id, services: $0) { $0.effectiveStatus == .paused } } ?? false
        }
    }

    /// What Resume machine on an unavailable chat does, decided on a fresh read of the machine:
    /// the recovery list that offered it may be a minute old, and a machine that turned live since
    /// must not be resumed again.
    enum RecoveryAttach: Equatable {
        /// Paused: ``CloudMachineSession/attach(origin:)``, which resumes it through Resume Machine's path.
        case resume
        /// Live without a connection: connect it (an app link connects; a legacy daemon is woken or
        /// connected again). ``CloudMachineSession/attach(origin:)`` only resumes a paused legacy
        /// machine, so it would do nothing here.
        case connect
        /// Live and connected: nothing to do; the chat reopens when it lists.
        case connected
        /// The read failed, or the machine is gone or failed.
        case refuse
    }

    static func recoveryAttach(fresh: Bool, status: CloudMachine.Status?, connected: Bool) -> RecoveryAttach {
        guard fresh, let status else { return .refuse }
        if status == .paused { return .resume }
        guard status.isLive else { return .refuse }
        return connected ? .connected : .connect
    }

    /// Refreshes, then reads the machine, then resumes or connects only on what that fresh read says.
    static func recoveryAttach(
        refresh: @MainActor () async -> Bool,
        machine: @MainActor () -> (status: CloudMachine.Status, connected: Bool)?,
        resume: @MainActor () -> Void,
        connect: @MainActor () -> Void
    ) async -> Bool {
        let fresh = await refresh()
        let read = machine()
        switch recoveryAttach(fresh: fresh, status: read?.status, connected: read?.connected ?? false) {
        case .resume:
            resume()
            return true
        case .connect:
            connect()
            return true
        case .connected:
            return true
        case .refuse:
            return false
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
