import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
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
    /// Sends each record and acts on the answer (`SessionRegistration`): a refusal is shown once
    /// through `notice` and not sent again unchanged; a failure with no answer backs off.
    private let registration: SessionRegistration<SessionRegistrationRecord>
    private var importing: Set<String> = []
    /// This Mac's name, resolved off the main actor (`MacName`).
    private var computerName: String?


    init(machines: MachineRegistry, notice: @escaping @MainActor (_ session: String, _ message: String) -> Bool,
         withdraw: @escaping @MainActor (_ session: String) -> Void) {
        self.machines = machines
        registration = SessionRegistration<SessionRegistrationRecord>(policy: .sessionRegistration, notice: notice,
                                                                      withdraw: withdraw)
        registration.onRetryDue = { [weak self] in self?.sync() }
    }

    func start() {
        observation?.cancel()
        Task { [weak self] in
            let name = await MacName().displayName()
            self?.computerName = name
            self?.sync()
        }
        let machines = machines
        observation = Task { [weak self] in
            for await _ in ObservationStream({ () -> [String] in
                let store = machines.local.store
                // connectionState changes on each reconnect; sync reads the connection epoch.
                let link: String = Self.homeKey(store.connectionState, epoch: store.connectionEpoch)
                let home: [String] = [String(store.personal.revision), String(store.personal.isLoaded),
                                      String(store.isProvisional), link]
                let daemons: [String] = machines.daemons.map { "\($0.machineID):\($0.store.isLoaded):\($0.store.registryID ?? "")" }
                let ssh: [String] = machines.ssh.map { "\($0.machineID):\($0.autoConnect)" }
                let servers: [String] = machines.servers.map { "\($0.machineID):\($0.autoConnect)" }
                return home + daemons + ssh + servers
            }) {
                self?.sync()
            }
        }
    }

    /// The home connection's part of the observation key: it changes on each reconnect.
    /// State case, pid, generation and epoch, never the capability list (main actor, each check). The epoch keys a
    /// same-process reconnect that lands within one check; it moves only with `connectionState` (no extra wakeup).
    static func homeKey(_ state: DaemonConnectionState, epoch: Int) -> String {
        switch state {
        case .connecting: "connecting"
        case .connected(let identity): "connected:\(identity.pid):\(identity.generation.rawValue):\(epoch)"
        case .disconnected: "disconnected"
        case .failed: "failed"
        }
    }

    /// Whether records can be sent to home now.
    static func canRegister(_ state: DaemonConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    /// Shows the refusal notices no window could show yet (a window became key).
    func showPendingNotices() { registration.showPendingNotices() }

    func stop() {
        observation?.cancel()
        registration.stop()
    }

    private func sync() {
        let home = machines.local
        guard home.store.personal.isLoaded, !home.store.isProvisional, Self.canRegister(home.store.connectionState),
              let connection = home.connection else { return }
        var present = Set<String>()
        for daemon in machines.daemons where daemon.store.isLoaded {
            guard let session = daemon.store.registryID, let identity = daemon.store.identity else { continue }
            present.insert(session)
            let name = machineName(daemon)
            // Unique and sorted: the daemon refuses a list that names a capability twice.
            let snapshot = SessionRegistrationRecord(machineName: name, sessionName: identity.session,
                                                     capabilities: Set(identity.capabilities).sorted(), transport: transport(daemon))
            let request = PutSessionRequest(sessionID: session, machineName: name, sessionName: identity.session,
                                            transport: snapshot.transport, capabilities: snapshot.capabilities)
            registration.submit(session: session, record: snapshot, machine: name ?? identity.session,
                                epoch: home.store.connectionEpoch) { _ = try await connection.putSession(request) }
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
        registration.retain(sessions: present)
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
        if let server = machines.server(daemon.machineID) { return ServerReachService.transport(server) }
        return .object(["kind": .string("cloud"), "machine": .string(daemon.machineID)])
    }
}
