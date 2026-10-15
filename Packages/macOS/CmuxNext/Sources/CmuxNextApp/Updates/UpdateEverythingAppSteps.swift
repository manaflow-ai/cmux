import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextUpdateEverything
import Foundation

/// Update Everything's update paths over the App's own (cx-1mbnu): Sparkle for the app,
/// `SSHService.install` and `cmux link machine update --to-bundled` for the machines' cmux daemons;
/// the daemon reads and agent CLI steps live in ``UpdateEverythingDaemon``.
@MainActor
final class UpdateEverythingAppSteps: UpdateEverythingSteps {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// This Mac, then every connected SSH and Cloud machine.
    func plan() async -> UpdateEverythingPlan {
        let machines = services.machines
        return await UpdateEverythingDaemon.plan(
            [(MachineRegistry.localID, UpdateEverythingMachine.thisMac, .local, machines.local)]
                + machines.ssh.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.host.label, .ssh, $0.daemon) }
                + machines.cloud.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.machine.title, .cloud, $0.daemon) },
            updater: services.updater)
    }

    /// ``plan()`` after a relaunch, once (bounded) the machines the run named are back and connected.
    func plan(waitingFor machineIDs: [String]) async -> UpdateEverythingPlan {
        let machines = services.machines
        _ = await UpdateEverythingDaemon.holds {
            machines.local.connection != nil && machineIDs.allSatisfy { machines.anyDaemon(machine: $0)?.connection != nil }
        }
        return await plan()
    }

    func updateDaemon(on machine: UpdateEverythingMachine) async throws {
        guard machine.kind != .local else { return }
        guard let daemon = services.machines.anyDaemon(machine: machine.id) else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
        let before = daemon.identity?.pid
        if machine.kind == .ssh {
            guard let session = services.machines.sshSession(machine.id) else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
            try await services.ssh.install(session)
        } else {
            // Gated like SSH's install: turned off by the organization (or no managed team) refuses.
            if let refusal = services.cloud.unavailableReason { throw ActionFailure(message: refusal) }
            guard let binary = services.cloud.move.cli, let socket = await daemon.connection?.endpoint?.socketPath else {
                throw ActionFailure(message: UpdateEverythingMachine.disconnected)
            }
            let answer = try await CloudMoveCLI(binary: binary).machineUpdate(socket: socket, toBundled: true)
            if !answer.ok { throw ActionFailure(message: CloudMachineUpdate.failure(answer, name: machine.name).0) }
            guard answer.updated else { return }
        }
        try await UpdateEverythingDaemon.waitForNewDaemon(daemon, replacing: before)
    }

    func outdatedAgents(on machine: UpdateEverythingMachine) async -> [UpdateEverythingChange] {
        await UpdateEverythingDaemon.outdatedAgents(services.machines.anyDaemon(machine: machine.id))
    }

    func updateAgents(on machine: UpdateEverythingMachine, continueThreads: Bool) async throws -> String? {
        try await UpdateEverythingDaemon.updateAgents(services.machines.anyDaemon(machine: machine.id), machine, continueThreads: continueThreads)
    }

    func installApp() throws {
        try services.updater.installAvailableUpdate()
    }
}
