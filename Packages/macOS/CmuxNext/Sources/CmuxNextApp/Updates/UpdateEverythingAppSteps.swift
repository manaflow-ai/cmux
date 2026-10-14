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
/// threads. It also reads the plan the confirmation shows.
@MainActor
final class UpdateEverythingAppSteps: UpdateEverythingSteps {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// This Mac, then every connected SSH and Cloud machine. A machine whose daemon does not
    /// answer within 45 s shows only its daemon update rather than holding the confirmation.
    func plan() async -> UpdateEverythingPlan {
        var bundled: String?
        if let binary = try? DaemonLauncherBinary.resolve() { bundled = await BundledCmuxTUI.commit(binary: binary) }
        var local = await machine(id: MachineRegistry.localID, name: UpdateEverythingStrings.thisMac, kind: .local,
                                  daemon: services.machines.local, bundled: nil)
        local.app = appChange()
        let remotes: [(String, String, UpdateEverythingMachine.Kind, DaemonService)] =
            services.machines.ssh.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.host.label, .ssh, $0.daemon) }
            + services.machines.cloud.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.machine.title, .cloud, $0.daemon) }
        var machines = [local]
        for (id, name, kind, daemon) in remotes {
            machines.append(await machine(id: id, name: name, kind: kind, daemon: daemon, bundled: bundled))
        }
        return UpdateEverythingPlan(machines: machines)
    }

    /// ``plan()`` after a relaunch: first waits (bounded) for this Mac and every machine set to
    /// connect, so a run the relaunch interrupted reaches the machines it updated before.
    func connectedPlan() async -> UpdateEverythingPlan {
        let daemons = [services.machines.local] + services.machines.ssh.filter(\.autoConnect).map(\.daemon)
            + services.machines.cloud.map(\.daemon)
        await withTaskGroup(of: Void.self) { group in
            for daemon in daemons { group.addTask { @MainActor in _ = await Self.connection(of: daemon) } }
        }
        return await plan()
    }

    /// The app as Finder names it ("cmux NEXT").
    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ProcessInfo.processInfo.processName
    }

    /// The app's update when Sparkle has found or staged one.
    private func appChange() -> UpdateEverythingChange? {
        let updater = services.updater
        guard updater.installUnavailableReason == nil else { return nil }
        let found: String?
        switch updater.flow.phase {
        case .ready(let version), .available(let version): found = version
        case .downloading: found = updater.status.detectedVersion
        case .hidden, .checking, .installing, .note: return nil
        }
        return UpdateEverythingChange(name: Self.appName, from: updater.status.version, to: updater.stagedVersion ?? found)
    }

    private func machine(id: String, name: String, kind: UpdateEverythingMachine.Kind, daemon: DaemonService,
                         bundled: String?) async -> UpdateEverythingMachine {
        var machine = UpdateEverythingMachine(id: id, name: name, kind: kind)
        let running = daemon.identity?.buildCommit
        if let bundled, kind != .local, running.map({ !bundled.hasPrefix($0) && !$0.hasPrefix(bundled) }) ?? true {
            machine.daemon = UpdateEverythingChange(name: UpdateEverythingStrings.daemonName, from: running.map { String($0.prefix(7)) },
                                                    to: String(bundled.prefix(7)))
        }
        guard daemon.supports(AgentUpdateCapability.name), let connection = daemon.connection,
              let answer = try? await connection.request(AgentUpdatePlanRequest(), timeout: .seconds(45)) else { return machine }
        machine.harnesses = answer.harnesses.map { UpdateEverythingChange(id: $0.id, name: $0.name ?? $0.id, from: $0.version, to: $0.latest) }
        machine.runningThreads = answer.runningThreads
        return machine
    }

    func updateDaemon(on machine: UpdateEverythingMachine) async throws {
        switch machine.kind {
        case .local:
            return
        case .ssh:
            guard let session = services.machines.sshSession(machine.id) else { throw ActionFailure(message: UpdateEverythingStrings.disconnected) }
            try await services.ssh.install(session)
        case .cloud:
            guard let session = services.machines.session(machine.id), let binary = services.cloud.move.cli,
                  let socket = await session.daemon.connection?.endpoint?.socketPath else {
                throw ActionFailure(message: UpdateEverythingStrings.disconnected)
            }
            let answer = try await CloudMoveCLI(binary: binary).machineUpdate(socket: socket, toBundled: true)
            if !answer.ok { throw ActionFailure(message: answer.error ?? answer.errorCode ?? "") }
        }
    }

    func updateAgents(on machine: UpdateEverythingMachine, continueThreads: Bool) async throws {
        // A daemon just replaced reconnects on its own: wait (bounded) for that connection.
        guard let daemon = services.machines.anyDaemon(machine: machine.id),
              let connection = await Self.connection(of: daemon) else { throw ActionFailure(message: UpdateEverythingStrings.disconnected) }
        let request = AgentUpdateApplyRequest(ids: machine.harnesses.compactMap(\.id), continueThreads: continueThreads)
        let answer = try await connection.request(request,
                                                  timeout: AgentUpdateApplyRequest.timeout)
        if let failed = answer.results.first(where: { !$0.ok }) {
            throw ActionFailure(message: UpdateEverythingStrings.failed(failed.id, failed.error ?? ""))
        }
    }

    /// The daemon's connection, waiting up to two minutes for a reconnect after its update.
    private static func connection(of daemon: DaemonService) async -> DaemonConnection? {
        if let connection = daemon.connection { return connection }
        // concurrency-allow: the observation task exits on cancellation; this bounds a reconnect
        return await withTaskGroup(of: DaemonConnection?.self) { group -> DaemonConnection? in
            group.addTask { @MainActor in
                for await connection in ObservationStream({ daemon.connection }) { if let connection { return connection } }
                return nil
            }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine to reconnect after its update
                try? await Task.sleep(for: .seconds(120))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func installApp() throws {
        try services.updater.installAvailableUpdate()
    }
}
