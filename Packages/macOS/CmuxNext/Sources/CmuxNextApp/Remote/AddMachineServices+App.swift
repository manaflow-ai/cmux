import CmuxNextActions
import CmuxNextCloud
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
            parse: hostDestination,
            candidates: { probe in
                // A candidate is Added only when it is one of the app's SSH machines; an acpmux peer
                // the app lacks stays pickable (it is connected, not enrolled again).
                let list = await cli?.candidates(probe: probe).flatMap { try? HostCandidate.parseList($0) }
                return list?.map { candidate in
                    var candidate = candidate
                    let peerHost = candidate.peerSSHDestination.flatMap { try? SSHDestination(parsing: $0) }
                    let routeNames = [candidate.name, candidate.dnsName, candidate.ip, peerHost?.host ?? "", peerHost?.displayName ?? ""]
                    candidate.inApp = machines.sshMachine(routeNames: routeNames) != nil
                    return candidate
                }
            },
            run: { command in
                // A joined machine's Check runs only while the switch is on: one left open across the
                // switch turning off fetches no token and runs nothing.
                if command.needsAccount, services.settings?.snapshot.machineJoin != true {
                    return AsyncThrowingStream { $0.finish(throwing: ActionFailure(message: JoinedMachineAction.labsOff)) }
                }
                #if DEBUG
                if command.needsAccount, services.debugFixtures.joinedMachines != nil {
                    return AsyncThrowingStream { for line in DebugAddDevice.joinedDoctorLines { $0.yield(line) }; $0.finish() }
                }
                #endif
                guard let cli else { return AsyncThrowingStream { $0.finish(throwing: ActionFailure(message: RemoteStrings.noClient)) } }
                return command.needsAccount ? accountRun(cli, command, auth: services.cloud.auth) : cli.lines(command.arguments)
            },
            install: { host, name in
                await .attempt { let session = try connect(host, name); try await ssh.install(session); return session.machineID }
            },
            connect: { host, name in (try? connect(host, name))?.machineID },
            record: { health.record($0, $1) },
            openWorkspace: { id in registry.perform("remote.newWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: id))) },
            copy: { CloudPresenter.copy($0) })
    }

    /// A run that reads the signed-in account's cmux access token on stdin (a joined machine's
    /// Check): its stdout lines once it ends. A failure says the app's words, never the CLI's
    /// stderr.
    private static func accountRun(_ cli: HostCLI, _ command: HostCommand, auth: CloudAuth) -> AsyncThrowingStream<String, any Error> {
        // concurrency-allow: bounded by one finished run: it holds the lines of a single doctor run's stdout
        // (its checklist, about a dozen), yielded once after the process ended; dropping one would drop a step.
        AsyncThrowingStream { continuation in
            // task-owner: one CLI run; the stream's end cancels it (SSHProcessRunner stops the process).
            let run = Task { @MainActor in
                guard auth.isSignedIn, let access = try? await auth.tokens().access else {
                    return continuation.finish(throwing: HostCLIStop(status: nil, message: RemoteStrings.signInToCheck))
                }
                guard let result = await cli.run(command.arguments, secret: access, deadline: .seconds(30), label: "machine doctor") else {
                    return continuation.finish(throwing: HostCLIStop(status: nil, message: RemoteStrings.checkStopped))
                }
                for line in result.stdout.split(whereSeparator: \.isNewline) { continuation.yield(String(line)) }
                if result.status == 0 { continuation.finish() } else {
                    continuation.finish(throwing: HostCLIStop(status: result.status, message: RemoteStrings.checkStopped))
                }
            }
            continuation.onTermination = { _ in run.cancel() }
        }
    }

    /// The field read as ssh takes it, for enroll and the app's connect alike. No port: enroll's ssh
    /// destination is `[user@]host` (acpmux `checked_host`); a port belongs in ~/.ssh/config, and an
    /// agent peer's URL port is its daemon's, not ssh's. An IPv6 host keeps its brackets
    /// (`leo@[fd7a::2]`) so the text parses back to the same host instead of a port.
    static func hostDestination(_ text: String) -> HostDestination? {
        guard let parsed = try? SSHDestination(parsing: text), parsed.port == nil else { return nil }
        let host = parsed.host.contains(":") ? "[\(parsed.host)]" : parsed.host
        return HostDestination(host: (parsed.user.map { "\($0)@" } ?? "") + host, shortName: parsed.displayName)
    }
}
