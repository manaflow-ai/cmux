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
                if let fixture = services?.debugFixtures.addDevice { return fixture.devices }
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
                _ = services?.registry.perform("newCloudMachine")
            },
            copy: { CloudPresenter.copy($0) },
            installTailscale: {
                if let url = URL(string: "https://tailscale.com/download/mac") { NSWorkspace.shared.openInBackground(url) }
            },
            // Labs labs.machineJoin: read at each opening, so the switch takes effect on the next one.
            machineJoin: { [weak services] in
                guard let services, services.settings?.snapshot.machineJoin == true else { return nil }
                #if DEBUG
                if let fixture = services.debugFixtures.addDevice?.join { return fixture }
                #endif
                return MachineJoinService.app(services)
            },
            // The line carries a single-use token: marked concealed and transient (nspasteboard.org) so
            // clipboard managers do not keep it.
            copyConcealed: { line in
                SystemPasswordPasteboard().write(line, markers: [ConcealedPasteboard.concealedType, ConcealedPasteboard.transientType])
            },
            showMachines: { [weak services] in _ = services?.registry.perform(RightSidebarMode.machines.actionID) })
    }
}

extension DeviceDirectory {
    static func app(_ services: AppServices) -> DeviceDirectory {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)).map { HostCLI(binary: $0, environment: SSHService.environment) }
        return DeviceDirectory(run: { await cli?.json($0, label: "device") },
                               removePhone: { [weak services] in await services?.iphone.removePhone(id: $0) },
                               setFullAccess: { [weak services] id, on in
                                   guard let services, let environment = QuitAgents.environment(services),
                                         let line = await AcpmuxPersonLine.open(environment) else { return false }
                                   defer { line.close() }
                                   // acpmux refuses an on from a connection that is not the person.
                                   if on, !line.isPerson { return false }
                                   return await line.call("_acpmux/pair_set", ["id": id, "fullAccess": on]) != nil
                               },
                               // A removed peer's SSH machine leaves the sidebar too (HQ #4877 break 8).
                               peerRemoved: { [weak services] peer in await services?.ssh.forgetMachines(reachingPeer: peer) })
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
        // Every successful list read feeds the Machines section too (Add Device's flip shows the row).
        // The read takes the store's ticket before it starts, so one that lands after a newer read is
        // dropped; one that lands after the switch turned off feeds nothing (the store emptied itself).
        let beginRead = { @MainActor [weak services] () -> Int? in
            guard let services, services.settings?.snapshot.machineJoin == true else { return nil }
            return services.joinedMachines.beginRead()
        }
        let store = { @MainActor [weak services] (rows: [JoinedMachine], ticket: Int) in
            guard let services, services.settings?.snapshot.machineJoin == true else { return }
            services.joinedMachines.finishRead(rows, ticket: ticket)
        }
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
                // With the switch off nothing is read: no token, no run.
                guard let ticket = await beginRead(), let cli, let access = await token(),
                      let run = await cli.run(["machine", "list", "--json", "--cloud-token-stdin"], secret: access, label: "machine list"),
                      run.status == 0, let rows = JoinedMachine.list(from: Data(run.stdout.utf8)) else { return nil }
                await store(rows, ticket)
                return rows
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
            },
            revoke: { id in
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "revoke", id, "--yes", "--json", "--cloud-token-stdin"], secret: access,
                                              label: "machine revoke") else { return false }
                return run.status == 0
            },
            // Its output may carry the new credential: only the status is read.
            rotate: { id in
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "rotate", id, "--json", "--cloud-token-stdin"], secret: access,
                                              label: "machine rotate") else { return false }
                return run.status == 0
            })
    }

    /// The platform does not serve the join here (404 `machine.not_found`), or this cmux has no
    /// `machine add` mint yet (an unknown flag).
    private nonisolated static func unavailable(_ run: SSHProcessResult) -> Bool {
        let text = run.stderr.lowercased()
        return text.contains("not_found") || text.contains("404") || text.contains("unexpected argument") || text.contains("unknown")
    }
}
