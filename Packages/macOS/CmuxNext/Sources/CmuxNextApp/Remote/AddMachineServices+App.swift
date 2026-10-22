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
        let ssh = services.ssh, health = services.machineHealth, registry = services.registry, machines = services.machines
        // The app's own cmux-tui, the one SSH machines and the agent daemon run.
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)).map { HostCLI(binary: $0, environment: SSHService.environment) }
        // Connected in the app under the Name field's name (the sidebar's label, saved in its transport).
        let connect = { (host: String, name: String) throws -> SSHMachineSession in
            let session = try ssh.connect(destination: host, session: nil, offerInstall: false)
            if session.host.label != name { session.host = session.host.named(name); ssh.rememberHost(session) }
            return session
        }
        return AddMachineServices(
            // No port: enroll's ssh destination is `[user@]host` (acpmux `checked_host`); a port belongs
            // in ~/.ssh/config.
            parse: { text in
                (try? SSHDestination(parsing: text)).flatMap { $0.port == nil ? HostDestination(host: $0.description, shortName: $0.displayName) : nil }
            },
            candidates: { probe in
                // A candidate is Added only when it is one of the app's SSH machines; an acpmux peer
                // the app lacks stays pickable (it is connected, not enrolled again).
                let list = await cli?.candidates(probe: probe).flatMap { try? HostCandidate.parseList($0) }
                return list?.map { candidate in
                    var candidate = candidate
                    let peerHost = candidate.peerDestination.flatMap { try? SSHDestination(parsing: $0) }
                    candidate.inApp = machines.sshMachine(named: [candidate.name, candidate.dnsName, candidate.ip, candidate.peer ?? "",
                                                                  peerHost?.host ?? "", peerHost?.displayName ?? ""]) != nil
                    return candidate
                }
            },
            run: { command in cli?.lines(command.arguments) ?? AsyncThrowingStream { $0.finish(throwing: ActionFailure(message: RemoteStrings.noClient)) } },
            install: { host, name in
                await .attempt { let session = try connect(host, name); try await ssh.install(session); return session.machineID }
            },
            connect: { host, name in (try? connect(host, name))?.machineID },
            record: { health.record($0, $1) },
            openWorkspace: { id in registry.perform("remote.newWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: id))) },
            copy: { CloudPresenter.copy($0) },
            // An agent peer's own destination keeps its port: the app connects it over ssh, it is
            // not enrolled again.
            parsePeer: { text in
                (try? SSHDestination(parsing: text)).map { HostDestination(host: $0.description, shortName: $0.displayName) }
            })
    }
}
