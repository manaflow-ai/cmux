import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextUpdateEverything
import CmuxNextUpdater
import Foundation

/// Update Everything's update paths over the App's own (cx-1mbnu): Sparkle for the app,
/// `SSHService.install` (RemoteInstaller) and `cmux link machine update --to-bundled` for the
/// machines' cmux daemons, and each machine daemon's `agent-update-*` for its agent CLIs and
/// threads (the logic lives in the daemon). It also reads the plan the confirmation shows.
@MainActor
final class UpdateEverythingAppSteps: UpdateEverythingSteps {
    private let services: AppServices
    /// How long a machine may take to answer again after its update, or to reconnect at launch.
    private static let reconnectLimit: Duration = .seconds(180)

    init(services: AppServices) {
        self.services = services
    }

    /// This Mac, then every connected SSH and Cloud machine, all asked at once. A machine whose
    /// daemon does not answer within 45 s shows only its daemon update.
    func plan() async -> UpdateEverythingPlan {
        var bundled: String?
        if let binary = try? DaemonLauncherBinary.resolve() { bundled = await BundledCmuxTUI.commit(binary: binary) }
        let targets: [(String, String, UpdateEverythingMachine.Kind, DaemonService)] =
            [(MachineRegistry.localID, UpdateEverythingMachine.thisMac, .local, services.machines.local)]
            + services.machines.ssh.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.host.label, .ssh, $0.daemon) }
            + services.machines.cloud.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.machine.title, .cloud, $0.daemon) }
        var machines = await withTaskGroup(of: (Int, UpdateEverythingMachine).self) { group in
            // Plain bindings: a tuple pattern captured by the task crashes the 6.3 region checker.
            for index in targets.indices {
                let id = targets[index].0, name = targets[index].1, kind = targets[index].2, daemon = targets[index].3
                group.addTask { @MainActor in (index, await self.machine(id: id, name: name, kind: kind, daemon: daemon, bundled: bundled)) }
            }
            var collected: [(Int, UpdateEverythingMachine)] = []
            for await machine in group { collected.append(machine) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        machines[0].app = appChange()
        return UpdateEverythingPlan(machines: machines)
    }

    /// ``plan()`` after a relaunch: first waits (bounded) until the machines the run named are
    /// back in the sidebar and connected (saved hosts and Cloud sign-in restore after launch).
    func plan(waitingFor machineIDs: [String]) async -> UpdateEverythingPlan {
        let machines = services.machines
        _ = await Self.holds(within: Self.reconnectLimit) {
            machines.local.connection != nil && machineIDs.allSatisfy { machines.anyDaemon(machine: $0)?.connection != nil }
        }
        return await plan()
    }

    /// The app as Finder names it ("cmux NEXT").
    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ProcessInfo.processInfo.processName
    }

    /// The app's update when Sparkle has staged one: only then does Install relaunch at once, so the
    /// run's last step is the relaunch (a found update still downloads, for the next run).
    private func appChange() -> UpdateEverythingChange? {
        let updater = services.updater
        guard updater.installUnavailableReason == nil, case .ready(let version) = updater.flow.phase else { return nil }
        return UpdateEverythingChange(name: Self.appName, from: updater.status.version, to: updater.stagedVersion ?? version)
    }

    private func machine(id: String, name: String, kind: UpdateEverythingMachine.Kind, daemon: DaemonService,
                         bundled: String?) async -> UpdateEverythingMachine {
        var machine = UpdateEverythingMachine(id: id, name: name, kind: kind)
        let running = daemon.identity?.buildCommit.flatMap { $0.isEmpty ? nil : $0 }
        if let bundled, kind != .local, running.map({ !bundled.hasPrefix($0) && !$0.hasPrefix(bundled) }) ?? true {
            machine.daemon = UpdateEverythingChange(name: UpdateEverythingMachine.daemonName, from: running.map { String($0.prefix(7)) },
                                                    to: String(bundled.prefix(7)))
        }
        let agents = await Self.agentPlan(daemon)
        machine.harnesses = agents.map(Self.changes) ?? []
        machine.runningThreads = agents?.runningThreads ?? 0
        return machine
    }

    private static func agentPlan(_ daemon: DaemonService) async -> AgentUpdatePlanRequest.Response? {
        guard daemon.supports(AgentUpdatePlanRequest.capability), let connection = daemon.connection else { return nil }
        return try? await connection.request(AgentUpdatePlanRequest(), timeout: .seconds(45))
    }

    private static func changes(_ plan: AgentUpdatePlanRequest.Response) -> [UpdateEverythingChange] {
        plan.harnesses.map { UpdateEverythingChange(id: $0.id, name: $0.name ?? $0.id, from: $0.version, to: $0.latest) }
    }

    func updateDaemon(on machine: UpdateEverythingMachine) async throws {
        guard let daemon = services.machines.anyDaemon(machine: machine.id) else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
        let before = daemon.identity?.pid
        switch machine.kind {
        case .local:
            return
        case .ssh:
            guard let session = services.machines.sshSession(machine.id) else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
            try await services.ssh.install(session)
        case .cloud:
            guard let binary = services.cloud.move.cli, let socket = await daemon.connection?.endpoint?.socketPath else {
                throw ActionFailure(message: UpdateEverythingMachine.disconnected)
            }
            let answer = try await CloudMoveCLI(binary: binary).machineUpdate(socket: socket, toBundled: true)
            if !answer.ok { throw ActionFailure(message: answer.error ?? answer.errorCode ?? "") }
            guard answer.updated else { return }
        }
        // The old connection stays until the new handshake: wait for the new daemon to answer.
        let answered = await Self.holds(within: Self.reconnectLimit) {
            daemon.connection != nil && daemon.identity.map { $0.pid != before } ?? false
        }
        if !answered { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
    }

    func outdatedAgents(on machine: UpdateEverythingMachine) async -> [UpdateEverythingChange] {
        guard let daemon = services.machines.anyDaemon(machine: machine.id) else { return [] }
        return await Self.agentPlan(daemon).map(Self.changes) ?? []
    }

    func updateAgents(on machine: UpdateEverythingMachine, continueThreads: Bool) async throws {
        guard let connection = services.machines.anyDaemon(machine: machine.id)?.connection else {
            throw ActionFailure(message: UpdateEverythingMachine.disconnected)
        }
        let request = AgentUpdateApplyRequest(ids: machine.harnesses.compactMap(\.id), continueThreads: continueThreads)
        let answer = try await connection.request(request, timeout: AgentUpdateApplyRequest.timeout)
        if let failed = answer.results.first(where: { !$0.ok }) {
            throw ActionFailure(message: UpdateEverythingOutcome.failureLine(failed.id, failed.error ?? ""))
        }
    }

    func installApp() throws {
        try services.updater.installAvailableUpdate()
    }

    /// Whether `condition` holds within `limit`: an observation, bounded by a one-shot deadline.
    private static func holds(within limit: Duration, until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a machine's reconnect
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { @MainActor in
                for await ready in ObservationStream({ condition() }) where ready { return true }
                return false
            }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine to answer after its update
                try? await Task.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
