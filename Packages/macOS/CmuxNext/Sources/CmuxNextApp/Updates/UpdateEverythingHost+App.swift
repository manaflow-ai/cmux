import AppKit
import CmuxNextDaemonService
import CmuxNextUpdateEverything

extension UpdateEverythingHost {
    /// Update Everything over the App's services (cx-1mbnu); the rest lives in its module.
    static func app(_ services: AppServices) -> Self {
        let machines = services.machines
        return Self(local: { machines.local }, remotes: {
            machines.ssh.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.host.label, .ssh, $0.daemon) }
                + machines.cloud.filter { $0.daemon.connection != nil }.map { ($0.machineID, $0.machine.title, .cloud, $0.daemon) }
        }, daemon: { machines.anyDaemon(machine: $0) }, installSSH: { id in
            guard let session = machines.sshSession(id) else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
            try await services.ssh.install(session)
        }, updateCloud: { socket in
            // Gated like SSH's install: turned off by the organization (or no managed team) refuses.
            if let refusal = services.cloud.unavailableReason { throw ActionFailure(message: refusal) }
            guard let binary = services.cloud.move.cli else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
            let answer = try await CloudMoveCLI(binary: binary).machineUpdate(socket: socket, toBundled: true)
            if !answer.ok { throw ActionFailure(message: UpdateEverythingMachine.failureText(answer.error)) }
            return answer.updated
        }, updater: services.updater, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    window: { services.windows.active?.window ?? NSApp.mainWindow },
                    journal: UpdateEverythingDaemon.journalURL(bundleID: services.environment.launch.bundleID))
    }
}
