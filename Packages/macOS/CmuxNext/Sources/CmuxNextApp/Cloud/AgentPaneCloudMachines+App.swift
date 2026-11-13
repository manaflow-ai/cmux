import CmuxNextActions
import CmuxNextAgentPane

extension AgentPaneCloudMachines {
    /// How old the App's machine list may be when a picker reads it: an open picker reads every
    /// few seconds, the server's list at most this often (the store also follows each machine's
    /// own link between reads).
    static let listAge: Duration = .seconds(60)

    /// The App's answers to `cloudMachine.*`: the signed-in account's machines (``CloudService``, never another user's or team's
    /// list), Open, Resume, Pause, Kill Machine and typing prewarm on one, run as the person's own; and each switch of team.
    func wire(_ services: AppServices) {
        let inventory: @MainActor (Duration) async -> Inventory = { [weak self, weak services] age in
            guard let services, services.cloud.isSignedIn else { return Inventory(signedIn: false, loaded: false, machines: []) }
            self?.readTeamsIfOld { [weak services] in await services?.cloud.auth.activeTeam.refresh() }
            // Complete only when this read's own refresh landed (the recovery list), or the store holds a server answer
            // within `age` (the picker): a superseded or failed refresh leaves the earlier registry, so a machine absent may exist.
            let complete = age == .zero ? await services.cloud.refresh() : await services.cloud.refresh(ifOlderThan: age)
            guard services.cloud.isSignedIn, services.cloud.hasLoadedCurrentMachines,
                  age != .zero || (services.cloud.lastError == nil && services.cloud.unavailableReason == nil) else {
                return Inventory(signedIn: services.cloud.isSignedIn, loaded: false, machines: [], team: TeamRowText.paneTeam(services.cloud.auth), teams: TeamRowText.paneTeams(services.cloud.auth))
            }
            let machines = services.machines.cloud.compactMap { session in
                session.effectiveStatus == .destroyed ? nil : Machine(id: session.machineID, name: session.machine.title, stage: session.stage.name, evictAt: session.machine.evictAt)
            }
            return Inventory(signedIn: true, loaded: true, machines: machines, account: services.cloud.account, complete: complete, team: TeamRowText.paneTeam(services.cloud.auth), teams: TeamRowText.paneTeams(services.cloud.auth))
        }
        teamWatch = TeamRowText.follow(services.cloud.auth) { [weak self] in self?.publishTeamChange() }
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
                connect: { services.machines.session(id)?.retry() }
            )
        }
        open = { [weak services] id in services.map { Self.perform("cloudOpenMachine", on: id, services: $0) { _ in true } } ?? false }
        resume = { [weak services] id in services.map { Self.perform("cloudResumeMachine", on: id, services: $0) { $0.effectiveStatus == .paused } } ?? false }
        pause = { [weak services] id in services.map { Self.perform("cloudPauseMachine", on: id, services: $0) { $0.effectiveStatus == .running } } ?? false }
        // Kill Machine is destructive: as the person's own run, the registry shows its confirmation sheet first.
        delete = { [weak services] id in services.map { Self.perform("cloudKillMachine", on: id, services: $0) { $0.effectiveStatus != .deleting } } ?? false }
        prewarm = { [weak services] id in
            guard let services else { return false }
            let cloud = services.cloud, status = services.machines.cloud.first(where: { $0.machineID == id })?.effectiveStatus
            let allowed = !services.registry.disabledFeatures.contains(.cloud) && cloud.mayCallCloud && cloud.unavailableReason == nil
            return await Self.prewarmIfPaused(allowed: allowed && cloud.isSignedIn && cloud.hasLoadedCurrentMachines, status: status) { try await cloud.resumeMachine(id, origin: .script) }
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
