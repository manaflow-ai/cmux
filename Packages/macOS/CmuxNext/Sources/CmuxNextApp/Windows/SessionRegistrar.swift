import CmuxNextDaemon
import Foundation
import Observation

/// Keeps the home session's session registry and the one-time migration in
/// step with the connected sessions (plans/cmux-next/data-model.md 1.1 and
/// 2.2): each loaded session is recorded with its name, transport and
/// capabilities (`put-session`), and a remote session's shared groups and
/// order are copied into personal rows once (`import-session-organization`,
/// a no-op when it already ran). The home daemon migrates its own groups at
/// open. Nothing runs against a home daemon without `profiles-v1`.
@MainActor
final class SessionRegistrar {
    private unowned let machines: MachineRegistry
    private var observation: Task<Void, Never>?
    /// Sessions recorded in this app run, with what was sent.
    private var recorded: [String: SessionSnapshot] = [:]
    private var importing: Set<String> = []
    /// This Mac's name, resolved off the main actor (`MacName`).
    private var computerName: String?

    struct SessionSnapshot: Hashable {
        var sessionName: String?
        var capabilities: [String]
        var transport: JSONValue
    }

    init(machines: MachineRegistry) {
        self.machines = machines
    }

    func start() {
        observation?.cancel()
        Task { [weak self] in
            let name = await MacName.computerName()
            self?.computerName = name
            self?.recorded.removeAll()
            self?.sync()
        }
        let machines = machines
        observation = Task { [weak self] in
            for await _ in Observations({ () -> [String] in
                [String(machines.local.store.personal.revision), String(machines.local.store.personal.isLoaded),
                 String(machines.local.store.isProvisional)]
                    + machines.daemons.map { "\($0.machineID):\($0.store.isLoaded):\($0.store.registryID ?? "")" }
                    + machines.ssh.map { "\($0.machineID):\($0.autoConnect)" }
            }) {
                self?.sync()
            }
        }
    }

    func stop() { observation?.cancel() }

    private func sync() {
        let home = machines.local
        guard home.store.personal.isLoaded, !home.store.isProvisional, let connection = home.connection else { return }
        for daemon in machines.daemons where daemon.store.isLoaded {
            guard let session = daemon.store.registryID, let identity = daemon.store.identity else { continue }
            let snapshot = SessionSnapshot(sessionName: identity.session, capabilities: identity.capabilities.sorted(),
                                           transport: transport(daemon))
            if recorded[session] != snapshot {
                recorded[session] = snapshot
                let request = PutSessionRequest(sessionID: session, machineName: machineName(daemon), sessionName: identity.session,
                                                transport: snapshot.transport, capabilities: snapshot.capabilities)
                home.send("put-session") { _ = try await $0.putSession(request) }
            }
            let record = home.store.personal.session(session)
            if daemon !== home, record?.migrated == false, !importing.contains(session) {
                importing.insert(session)
                let request = Self.organization(of: daemon.store, session: session)
                Task { [weak self] in
                    _ = try? await connection.importOrganization(request)
                    self?.importing.remove(session)
                }
            }
        }
    }

    /// A remote daemon's shared groups and sidebar order, as the one-time
    /// import payload.
    static func organization(of store: DaemonStore, session: String) -> ImportSessionOrganizationRequest {
        let groups = store.groups.sorted { $0.index < $1.index }.map {
            ImportSessionOrganizationRequest.Group(id: $0.id, name: $0.name, color: $0.color, collapsed: $0.collapsed)
        }
        let ordered = store.sidebarSections.flatMap(\.workspaces)
        let workspaces = ordered.compactMap { workspace in
            workspace.key.map { ImportSessionOrganizationRequest.Workspace(workspaceKey: $0, group: workspace.group) }
        }
        return ImportSessionOrganizationRequest(sessionID: session, groups: groups, workspaces: workspaces)
    }

    private func machineName(_ daemon: DaemonService) -> String? {
        if daemon.isLocal { return computerName }
        return machines.machineName(daemon.machineID)
    }

    /// How to reconnect, never a secret: an SSH machine's route, session,
    /// cmux-tui path and whether it connects at launch (`SSHService`).
    private func transport(_ daemon: DaemonService) -> JSONValue {
        if daemon.isLocal { return .object(["kind": .string("local")]) }
        if let ssh = machines.sshSession(daemon.machineID) { return SSHService.transport(ssh) }
        return .object(["kind": .string("cloud"), "machine": .string(daemon.machineID)])
    }
}
