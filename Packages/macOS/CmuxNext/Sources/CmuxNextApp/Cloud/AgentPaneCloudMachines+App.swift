import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemonService

extension AgentPaneCloudMachines {
    /// The App's answers to `cloudMachine.*`: the signed-in account's machines (``CloudService``, never another user's or team's
    /// list), Open, Resume, Pause, Kill Machine and typing prewarm on one, run as the person's own; and each switch of team.
    func wire(_ services: AppServices) {
        let inventory: @MainActor (Duration) async -> Inventory = { [weak self, weak services] age in
            guard let services, services.cloud.isSignedIn else { return Inventory(signedIn: false, loaded: false, machines: []) }
            self?.readTeamsIfOld { [weak services] in await services?.cloud.auth.activeTeam.refresh() }
            // A cold start shows the list last answered, marked last seen, while the read runs behind it (never the recovery list).
            if age != .zero, !services.cloud.hasLoadedCurrentMachines, let kept = services.cloud.lastSeen.inventory(for: services.cloud.account, team: TeamRowText.paneTeam(services.cloud.auth), teams: TeamRowText.paneTeams(services.cloud.auth), refresh: { [weak services] in _ = await services?.cloud.refresh(ifOlderThan: age) }) { return kept }
            // Complete only when this read's own refresh landed (the recovery list), or the store holds a server answer
            // within `age` (the picker): a superseded or failed refresh leaves the earlier registry, so a machine absent may exist.
            let complete = age == .zero ? await services.cloud.refresh() : await services.cloud.refresh(ifOlderThan: age)
            guard services.cloud.isSignedIn, services.cloud.hasLoadedCurrentMachines,
                  age != .zero || (services.cloud.lastError == nil && services.cloud.unavailableReason == nil) else {
                return Inventory(signedIn: services.cloud.isSignedIn, loaded: false, machines: [], team: TeamRowText.paneTeam(services.cloud.auth), teams: TeamRowText.paneTeams(services.cloud.auth))
            }
            let machines = services.machines.cloud.compactMap { session in
                session.effectiveStatus == .destroyed ? nil : Machine(id: session.machineID, name: session.machine.title, stage: session.stage.name, evictAt: session.machine.evictAt,
                                                                       size: Machine.Size(session.machine.size))
            }
            if complete { services.cloud.lastSeen.keep(machines, for: services.cloud.account) } // only a whole server answer
            return Inventory(signedIn: true, loaded: true, machines: machines, account: services.cloud.account, complete: complete, team: TeamRowText.paneTeam(services.cloud.auth), teams: TeamRowText.paneTeams(services.cloud.auth), plan: await self?.planReads.read(account: services.cloud.account) { try await services.cloud.appOps("cloud.plan.get", .object([:]), nil, .script) } ?? .unknown) // cloud.plan.get, else unknown
        }
        teamWatch = TeamRowText.follow(services.cloud.auth) { [weak self] in self?.publishTeamChange() }
        list = { await inventory(Self.listAge) }
        recoveryList = { await inventory(.zero) }
        // The facts the typing prewarm and wake on intent (hidden `cloud.wakeOnIntent`) give their Rust rules.
        let facts: @MainActor (String) -> [String: Any] = { [weak services] id in guard let services else { return [:] }
            let cloud = services.cloud, status = services.machines.cloud.first(where: { $0.machineID == id })?.effectiveStatus, allowed = !services.registry.disabledFeatures.contains(.cloud) && cloud.mayCallCloud && cloud.unavailableReason == nil
            var facts: [String: Any] = ["enabled": CloudTunables.wakeOnIntent.value, "allowed": allowed && cloud.isSignedIn, "loaded": cloud.hasLoadedCurrentMachines]
            if let status { facts["status"] = status.rawValue }
            return facts
        }
        let wake = AgentPaneCloudWakeOnIntent(port: .init(ask: { CloudHandlerRules().ask($0, $1) }, facts: facts,
            resume: { [weak services] id in (try? await services?.cloud.resumeMachine(id, origin: .script)) != nil }, pause: { [weak services] id in try? await services?.cloud.pauseMachine(id) }))
        wakeHint = { id, signal, version in await wake.hint(machine: id, signal: signal, version: version) }
        attach = { [weak services] id in wake.input(machine: id)
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
        open = { [weak services] id in wake.input(machine: id); return services.map { Self.perform("cloudOpenMachine", on: id, services: $0) { _ in true } } ?? false }
        resume = { [weak services] id in services.map { Self.perform("cloudResumeMachine", on: id, services: $0) { $0.effectiveStatus == .paused } } ?? false }
        pause = { [weak services] id in services.map { Self.perform("cloudPauseMachine", on: id, services: $0) { $0.effectiveStatus == .running } } ?? false }
        // Kill Machine is destructive: as the person's own run, the registry shows its confirmation sheet first.
        delete = { [weak services] id in services.map { Self.perform("cloudKillMachine", on: id, services: $0) { $0.effectiveStatus != .deleting } } ?? false }
        // The rule (which machine a typing hint resumes, and the pause after a failed resume) is Rust's:
        // `cloud_handler_prewarm` (cmux-cloud-handlers `decide::prewarm`). This keeps the clock of each failure.
        let failures = AgentPaneCloudPrewarmFailures()
        prewarm = { [weak services] id in wake.input(machine: id)
            guard let services else { return false }
            let status = services.machines.cloud.first(where: { $0.machineID == id })?.effectiveStatus
            var facts = facts(id)
            if let ms = failures.sinceFailureMs(id) { facts["sinceFailureMs"] = ms }
            // An FFI without the op (nil) leaves the old rule: `prewarmIfPaused` below still resumes only a paused machine.
            if let answer = CloudHandlerRules().ask("cloud_handler_prewarm", facts), answer["resume"] as? Bool != true { return false }
            let resumed = await Self.prewarmIfPaused(allowed: true, status: status) { try await services.cloud.resumeMachine(id, origin: .script) }
            if resumed { failures.clear(id) } else { failures.failed(id) }
            return resumed
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
