import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextServer
import Foundation

/// The Add Machine card's services in the app: the bundled cmux-tui for the CLI runs, `SSHService`
/// for the install path and the connect, the Machines section's health store.
extension AddMachineServices {
    static func app(_ services: AppServices) -> AddMachineServices {
        let ssh = services.ssh, health = services.machineHealth, registry = services.registry
        // The app's own cmux-tui, the one SSH machines and the agent daemon run.
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
        let connect = { (host: String) in try ssh.connect(destination: host, session: nil, offerInstall: false) }
        return AddMachineServices(
            parse: { text in (try? SSHDestination(parsing: text)).map { HostDestination(host: $0.description, shortName: $0.displayName) } },
            candidates: { await cli?.candidates().flatMap { try? HostCandidate.parseList($0) } },
            run: { command in cli?.lines(command.arguments) ?? AsyncThrowingStream { $0.finish(throwing: ActionFailure(message: RemoteStrings.noClient)) } },
            install: { host in
                do {
                    let session = try connect(host)
                    try await ssh.install(session)
                    return .installed(machineID: session.machineID)
                } catch {
                    return .failed((error as? ActionFailure)?.message ?? error.localizedDescription)
                }
            },
            connect: { host in (try? connect(host))?.machineID },
            record: { health.record($0, $1) },
            openWorkspace: { id in registry.perform("remote.newWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: id))) },
            copy: { CloudPresenter.copy($0) })
    }
}
