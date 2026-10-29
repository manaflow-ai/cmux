import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextServer
import Foundation

/// Add Device in the app (plans/cmux-next/add-device-DESIGN.md): the list from the bundled
/// cmux-tui, and the hand-offs to the Add Machine and Add Server cards, so the enroll and the
/// approval each stay one flow. Every add or remove reads the device list again.
extension AddDeviceServices {
    static func app(_ services: AppServices) -> AddDeviceServices {
        AddDeviceServices(
            list: { [weak services] in
                #if DEBUG
                if let fixture = DebugAddDevice.listing { return fixture.devices }
                #endif
                return await services?.devices.read()
            },
            addComputer: { [weak services] address, name in
                guard let services else { return }
                let card = services.addMachine
                card.open(destination: address, name: name, over: NSApp.mainWindow)
                card.model.perform(.add)
                // task-owner: ends with the enroll this click started
                Task { @MainActor [weak services] in _ = await card.finished(); await services?.devices.refresh() }
            },
            addByName: { [weak services] in _ = services?.registry.perform("machine.add") },
            enterCode: { [weak services] in _ = services?.registry.perform("server.addServer") },
            // Signed out, New Cloud Machine is refused: sign-in starts instead (the agent pane's same fallback).
            newCloudMachine: { [weak services] in
                guard let registry = services?.registry, !registry.perform("newCloudMachine") else { return }
                _ = registry.perform("palette.auth.signIn")
            },
            copy: { CloudPresenter.copy($0) },
            // Labs labs.machineJoin: read at each opening, so the switch takes effect on the next one.
            machineJoin: { [weak services] in
                guard let services, services.settings?.snapshot.machineJoin == true else { return nil }
                #if DEBUG
                if let fixture = DebugAddDevice.listing?.join { return fixture }
                #endif
                return MachineJoinService.app(services)
            },
            // The line carries a single-use token: marked concealed and transient (nspasteboard.org) so
            // clipboard managers do not keep it.
            copyConcealed: { line in
                SystemPasswordPasteboard().write(line, markers: [ConcealedPasteboard.concealedType, ConcealedPasteboard.transientType])
            })
    }
}

extension DeviceDirectory {
    static func app(_ services: AppServices) -> DeviceDirectory {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)).map { HostCLI(binary: $0, environment: SSHService.environment) }
        return DeviceDirectory(run: { arguments in
                                   #if DEBUG
                                   if let fixture = await MainActor.run(body: { DebugDevicesFixture.run(arguments) }) { return fixture }
                                   #endif
                                   return await cli?.json(arguments, label: "device")
                               },
                               removePhone: { [weak services] in await services?.iphone.removePhone(id: $0) },
                               setFullAccess: { [weak services] id, on in
                                   #if DEBUG
                                   if let fixture = DebugDevicesFixture.set(id, on: on) { return fixture }
                                   #endif
                                   guard let services, let environment = QuitAgents.environment(services),
                                         let line = await AcpmuxPersonLine.open(environment) else { return false }
                                   defer { line.close() }
                                   // acpmux refuses an on from a connection that is not the person.
                                   if on, !line.isPerson { return false }
                                   return await line.call("_acpmux/pair_set", ["id": id, "fullAccess": on]) != nil
                               })
    }
}

/// The one-line join in the app (Labs `labs.machineJoin`): each call is one short run of the bundled
/// `cmux` CLI (`machine add|list|doctor`), handed the signed-in account's cmux access token on stdin
/// (`--cloud-token-stdin`), never in argv, the environment or a log. The card shows the app's own
/// words for a failure, never the CLI's stderr.
extension MachineJoinService {
    static func app(_ services: AppServices) -> MachineJoinService {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
        let auth = services.cloud.auth
        let token: @Sendable () async -> String? = { @MainActor in
            guard auth.isSignedIn else { return nil }
            return try? await auth.tokens().access
        }
        let machines = services.machines
        return MachineJoinService(
            mint: { name in
                guard let cli else { return .failure(.failed) }
                guard let access = await token() else { return .failure(.signedOut) }
                let arguments = ["machine", "add", "--json", "--no-wait", "--cloud-token-stdin"] + (name.map { ["--name", $0] } ?? [])
                guard let run = await cli.run(arguments, secret: access, label: "machine add") else { return .failure(.failed) }
                if run.status == 0 { return JoinLine.decode(Data(run.stdout.utf8)).map(Result.success) ?? .failure(.failed) }
                return .failure(Self.unavailable(run) ? .unavailable : .failed)
            },
            list: {
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "list", "--json", "--cloud-token-stdin"], secret: access, label: "machine list"),
                      run.status == 0 else { return nil }
                return JoinedMachine.list(from: Data(run.stdout.utf8))
            },
            doctor: { id in
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "doctor", id, "--json", "--cloud-token-stdin"], secret: access,
                                              deadline: .seconds(30), label: "machine doctor") else { return [] }
                return MachineJoinService.steps(run.stdout)
            },
            // A machine connecting or leaving is the mesh change the app sees; the first value
            // (the list as it is now) is not a change.
            meshChanges: {
                // A change only asks for one list read, so a backlog collapses to the newest signal.
                AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    // task-owner: ends when the card's watch stops (the stream's termination cancels it).
                    let follow = Task { @MainActor in
                        var first = true
                        for await _ in ObservationStream({ machines.daemons.map(\.machineID) }) {
                            if first { first = false; continue }
                            continuation.yield()
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in follow.cancel() }
                }
            })
    }

    /// The platform does not serve the join here (404 `machine.not_found`), or this cmux has no
    /// `machine add` mint yet (an unknown flag).
    private nonisolated static func unavailable(_ run: SSHProcessResult) -> Bool {
        let text = run.stderr.lowercased()
        return text.contains("not_found") || text.contains("404") || text.contains("unexpected argument") || text.contains("unknown")
    }
}
