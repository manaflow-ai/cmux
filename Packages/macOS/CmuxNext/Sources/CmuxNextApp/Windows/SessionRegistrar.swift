import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups
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
    /// What was sent for each session and its answer (`SessionRegistrationLedger`): a refusal is
    /// shown once and not sent again unchanged; a failure with no answer backs off.
    private var ledger = SessionRegistrationLedger<SessionSnapshot>()
    /// One-shot backoff deadlines of failed sends with no answer, per session.
    private var retries: [String: DemandTimer] = [:]
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
            let name = await MacName().displayName()
            self?.computerName = name
            self?.sync()
        }
        let machines = machines
        observation = Task { [weak self] in
            for await _ in ObservationStream({ () -> [String] in
                [String(machines.local.store.personal.revision), String(machines.local.store.personal.isLoaded),
                 String(machines.local.store.isProvisional),
                 machines.local.connection.map { String(describing: ObjectIdentifier($0)) } ?? ""]
                    + machines.daemons.map { "\($0.machineID):\($0.store.isLoaded):\($0.store.registryID ?? "")" }
                    + machines.ssh.map { "\($0.machineID):\($0.autoConnect)" }
                    + machines.servers.map { "\($0.machineID):\($0.autoConnect)" }
            }) {
                self?.sync()
            }
        }
    }

    func stop() {
        observation?.cancel()
        for retry in retries.values { retry.cancel() }
        retries.removeAll()
    }

    private func sync() {
        let home = machines.local
        guard home.store.personal.isLoaded, !home.store.isProvisional, let connection = home.connection else { return }
        for daemon in machines.daemons where daemon.store.isLoaded {
            guard let session = daemon.store.registryID, let identity = daemon.store.identity else { continue }
            let snapshot = SessionSnapshot(sessionName: identity.session, capabilities: identity.capabilities.sorted(),
                                           transport: transport(daemon))
            if ledger.shouldSend(session: session, record: snapshot, connection: ObjectIdentifier(connection)) {
                let request = PutSessionRequest(sessionID: session, machineName: machineName(daemon), sessionName: identity.session,
                                                transport: snapshot.transport, capabilities: snapshot.capabilities)
                let machine = machineName(daemon) ?? identity.session
                // task-owner: one put-session; its answer goes to the ledger on the main actor
                Task { [weak self] in
                    do {
                        _ = try await connection.putSession(request)
                        self?.ledger.succeeded(session: session, record: snapshot)
                    } catch {
                        home.logger.error("put-session \(session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                        self?.notRecorded(session, snapshot, machine: machine,
                                          failure: SessionRegistrationLedger<SessionSnapshot>.classify(error))
                    }
                }
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

    /// A `put-session` the daemon did not record: a refusal is shown once (the machine is not saved
    /// for restore); a failure with no answer is sent again after the ledger's backoff.
    private func notRecorded(_ session: String, _ snapshot: SessionSnapshot, machine: String?,
                             failure: SessionRegistrationLedger<SessionSnapshot>.Failure) {
        let outcome = ledger.failed(session: session, record: snapshot, failure: failure)
        if let reason = outcome.refusal { Self.showNotSaved(machine: machine, reason: reason) }
        guard let delay = outcome.retryAfter else { return }
        let timer = retries[session] ?? DemandTimer(owner: "SessionRegistrar.retry")
        retries[session] = timer
        timer.schedule(after: delay) { @MainActor [weak self] in
            self?.ledger.retryDue(session: session)
            self?.sync()
        }
    }

    /// The machine is left out of the session registry, so the next launch does not restore it.
    private static func showNotSaved(machine: String?, reason: String) {
        let message = WindowStrings.machineNotSavedForRestore(machine: machine, reason: reason)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        CmuxToastCenter.shared.show(CmuxToast(id: "session-registrar.not-saved", message: message, duration: .seconds(12)),
                                    in: window)
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
