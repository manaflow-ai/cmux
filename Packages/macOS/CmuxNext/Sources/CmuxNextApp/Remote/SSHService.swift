import AppKit
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Observation
import os

/// SSH machines: "Connect to Machine…", their sessions in `MachineRegistry`,
/// the saved-hosts list, disconnect and forget, and installing the pinned
/// cmux-tui. Saved hosts are the home session's session registry
/// (plans/cmux-next/data-model.md 1.1): each connected machine is recorded
/// by `SessionRegistrar` with an SSH `transport`, and the records come back
/// here at launch. There is no second registry.
///
/// Reconnect is event-driven: each daemon loop keeps its capped backoff
/// after a failure, and the app becoming active, the Mac waking and a
/// network path change (the daemon's own monitor) wake it. The link's gate
/// (`SSHConnectionMachine`) decides which events may retry a failure.
@Observable
final class SSHService {
    @ObservationIgnored private let machines: MachineRegistry
    @ObservationIgnored let paths: SSHPaths
    @ObservationIgnored private let binary: URL?
    @ObservationIgnored private let installer: RemoteInstaller
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.ssh")
    /// Runs `remote.install` through the registry's confirmation (set by the handlers).
    @ObservationIgnored var offerInstall: ((SSHMachineSession) -> Void)?
    /// Forgotten machines, so a stale registry echo does not bring them back.
    @ObservationIgnored private var forgotten: Set<String> = []

    init(machines: MachineRegistry, bundleID: String?) {
        self.machines = machines
        paths = SSHPaths.standard(bundleID: bundleID)
        binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        installer = RemoteInstaller(paths: paths)
    }

    /// Why SSH machines cannot connect in this build, or nil.
    var unavailableReason: String? { binary == nil ? RemoteStrings.noClient : nil }

    var sessions: [SSHMachineSession] { machines.ssh }

    // MARK: Lifecycle

    func start() {
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.wakeAll(.appActivated)
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                self?.wakeAll(.systemWake)
            }
        })
        let machines = machines
        observers.append(Task { [weak self] in
            for await records in Observations({ machines.local.store.personal.isLoaded ? machines.local.store.personal.sessions : [] }) {
                self?.restore(records)
            }
        })
    }

    func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        for session in machines.ssh { session.close() }
    }

    private func wakeAll(_ wake: SSHConnectionMachine.Wake) {
        for session in machines.ssh where session.autoConnect { session.wake(wake) }
    }

    /// Adds machines saved in the session registry that this run has not
    /// seen; those the user left connected connect again.
    private func restore(_ records: [SessionRecord]) {
        for record in records {
            guard let fields = record.transport.flatMap(Self.fields), let host = SSHHost(transportFields: fields),
                  !forgotten.contains(host.machineID), machines.sshSession(host.machineID) == nil,
                  let session = makeSession(host) else { continue }
            session.autoConnect = fields["connect"] != "false"
            if session.autoConnect { session.connect() }
        }
    }

    // MARK: Connect, disconnect, forget

    /// Connects to `destination` (or reconnects the saved machine it names).
    @discardableResult
    func connect(destination text: String, session name: String?, binary: String? = nil, stateDir: String? = nil,
                 offerInstall: Bool) throws -> SSHMachineSession {
        if let reason = unavailableReason { throw ActionFailure(message: reason) }
        let destination: SSHDestination
        do { destination = try SSHDestination(parsing: text) } catch { throw ActionFailure(message: RemoteStrings.invalidDestination(text, error)) }
        let sessionName: String
        do { sessionName = try RemoteSessionName.validate(name) } catch { throw ActionFailure(message: RemoteStrings.invalidSession(name ?? "")) }
        let host: SSHHost
        do {
            host = try SSHHost(destination: destination, session: sessionName, remoteBinary: nonEmpty(binary) ?? SSHHost.defaultRemoteBinary,
                               remoteStateDir: nonEmpty(stateDir))
        } catch {
            throw ActionFailure(message: RemoteStrings.invalidPath((error as? SSHHost.Invalid)?.field == "remote_state_dir" ? stateDir ?? "" : binary ?? ""))
        }
        forgotten.remove(host.machineID)
        let session = machines.sshSession(host.machineID) ?? makeSession(host)
        guard let session else { throw ActionFailure(message: RemoteStrings.noClient) }
        session.offersInstall = offerInstall
        if offerInstall { offerInstallWhenOld(session) }
        if session.linkStatus == .offline || session.daemon.connection == nil {
            session.connect()
        } else {
            session.wake(.user)
        }
        logger.info("connect \(host.destination.description, privacy: .public) session \(host.session, privacy: .public)")
        return session
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    func reconnect(_ session: SSHMachineSession) {
        if session.linkStatus == .offline { session.connect() } else { session.wake(.user) }
    }

    func disconnect(_ session: SSHMachineSession) {
        session.disconnect()
        logger.info("disconnected \(session.host.destination.description, privacy: .public)")
    }

    /// Disconnects and removes the machine from the saved list, with its
    /// personal organization (order, groups, pins) in the home session.
    func forget(_ session: SSHMachineSession) async {
        forgotten.insert(session.machineID)
        let sessionID = session.daemon.identity?.sessionID ?? recordID(for: session.host)
        session.close()
        _ = machines.removeSSH(session.machineID)
        guard let sessionID, machines.local.supports(DaemonCapabilities.profiles), let home = machines.local.connection else { return }
        do {
            try await home.forgetSession(sessionID, force: true)
        } catch {
            logger.error("forget-session \(sessionID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The registry record's session id for `host`, when it was saved.
    private func recordID(for host: SSHHost) -> String? {
        machines.local.store.personal.sessions.first { record in
            record.transport.flatMap(Self.fields).flatMap(SSHHost.init(transportFields:))?.machineID == host.machineID
        }?.id
    }

    private func makeSession(_ host: SSHHost) -> SSHMachineSession? {
        guard let binary else { return nil }
        let session = SSHMachineSession(host: host, binary: binary, paths: paths, environment: Self.environment)
        session.daemon.workTracker = machines.local.workTracker
        session.onStatusChange = { [weak self] session, status in self?.statusChanged(session, status) }
        machines.add(session)
        return session
    }

    /// A daemon that answers but is too old for this app (a refused
    /// handshake, or limited features) gets the same install offer as a
    /// missing binary, once per user-initiated connect.
    private func offerInstallWhenOld(_ session: SSHMachineSession) {
        let machines = machines
        // task-owner: ends at the first answer from the machine's daemon, or when the session is forgotten
        Task { [weak self, weak session] in
            for await level in Observations({ session.flatMap { machines.compatibility(of: $0.daemon)?.level } }) {
                guard let session, session.offersInstall, machines.sshSession(session.machineID) === session else { return }
                guard let level else { continue }
                if level != .current {
                    session.offersInstall = false
                    self?.offerInstall?(session)
                }
                return
            }
        }
    }

    private func statusChanged(_ session: SSHMachineSession, _ status: SSHConnectionMachine.Status) {
        logger.info("\(session.host.destination.description, privacy: .public): \(String(describing: status), privacy: .public)")
        if case .needsInstall(let need) = status, need.canInstall, session.offersInstall {
            session.offersInstall = false
            offerInstall?(session)
        }
        if status == .connected { session.lastError = nil }
    }

    // MARK: Install

    /// Installs the app's cmux-tui build on the machine and reconnects.
    func install(_ session: SSHMachineSession) async throws {
        guard let binary else { throw ActionFailure(message: RemoteStrings.noClient) }
        guard let commit = await BundledCmuxTUI.commit(binary: binary) else { throw ActionFailure(message: RemoteStrings.noPinnedBuild) }
        let link = session.link, host = session.host
        let environment = await Self.environment()
        var report = await link.lastReport
        if report?.platform == nil { report = try? await link.probe(environment) }
        guard let platform = report?.platform else { throw ActionFailure(message: RemoteStrings.unsupportedPlatform(host.label)) }
        // The running daemon of this session, restarted onto the new build.
        let daemonPID = session.daemon.connection != nil ? session.daemon.identity?.pid : nil
        await link.handle(.installStarted)
        session.lastError = nil
        do {
            session.installPhase = .manifest
            let plan = try await installer.plan(commit: commit, platform: platform, remoteBinary: host.remoteBinary)
            try await installer.install(plan, on: host, daemonPID: daemonPID, environment: environment) { phase in
                // task-owner: one main-actor hop per install step
                Task { @MainActor in session.installPhase = phase }
            }
            session.installPhase = nil
            logger.info("installed cmux-tui \(commit, privacy: .public) on \(host.destination.description, privacy: .public)")
            await link.handle(.installFinished(.success))
            reconnect(session)
        } catch {
            session.installPhase = nil
            let message = RemoteStrings.installFailure(error)
            session.lastError = message
            await link.handle(.installFinished(.failure(message)))
            throw ActionFailure(message: message)
        }
    }

    // MARK: Helpers

    /// The environment ssh runs with: the app's own process identity (HOME,
    /// USER, SSH_AUTH_SOCK for the user's agent) plus the login shell's
    /// PATH for ProxyCommand helpers. Never a token or key.
    @Sendable static func environment() async -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        var env = await TerminalEnvironment.shared(base: base)()
        for key in TerminalEnvironment.daemonIdentityKeys { if let value = base[key] { env[key] = value } }
        return env
    }

    /// The registry transport for `session`.
    static func transport(_ session: SSHMachineSession) -> JSONValue {
        var fields = session.host.transportFields.mapValues(JSONValue.string)
        fields["connect"] = .string(session.autoConnect ? "true" : "false")
        return .object(fields)
    }

    static func fields(_ transport: JSONValue) -> [String: String]? {
        guard case .object(let object) = transport else { return nil }
        return object.compactMapValues { value in
            if case .string(let text) = value { return text }
            return nil
        }
    }
}
