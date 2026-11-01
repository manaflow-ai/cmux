import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextServer
import Foundation
import Observation
import os
import CmuxNextWakeups

/// SSH machines: "Connect to Machine…", their sessions in `MachineRegistry`,
/// the saved-hosts list, disconnect and forget, and installing the pinned
/// cmux-tui. Saved hosts are the home session's session registry
/// (plans/cmux-next/data-model.md 1.1): each connected machine is recorded
/// by `SessionRegistrar` with an SSH `transport`, and the records come back
/// here at launch. A host that has not connected yet has no session id, so
/// it waits in the home daemon's saved-hosts projection until the registry
/// holds it (`SSHService+SavedHosts`).
///
/// Reconnect is event-driven: each daemon loop keeps its capped backoff
/// after a failure, and the app becoming active, the Mac waking and a
/// network path change (the daemon's own monitor) wake it. The link's gate
/// (`SSHConnectionMachine`) decides which events may retry a failure.
@Observable
final class SSHService {
    @ObservationIgnored let machines: MachineRegistry
    @ObservationIgnored let paths: SSHPaths
    @ObservationIgnored private let binary: URL?
    @ObservationIgnored private let installer: RemoteInstaller
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.ssh")
    /// Runs `remote.install` through the registry's confirmation (set by the handlers).
    @ObservationIgnored var offerInstall: ((SSHMachineSession) -> Void)?
    /// A written Forget's acpmux peer removal (HQ #4877 break 8); tests replace its `remove`.
    @ObservationIgnored let peerForgets: SSHPeerForgets
    /// Forgotten machines, so a stale registry echo does not bring them back.
    @ObservationIgnored private var forgotten: Set<String> = []
    /// Saved hosts on the home daemon's current connection (`SSHService+SavedHosts`).
    @ObservationIgnored var savedHosts: (connection: ObjectIdentifier, store: SavedHostsStore)?
    /// Machines with an install (and its handoffs) running from this app: one at a time (cx-3r9mt).
    @ObservationIgnored private var installing: Set<String> = []
    /// Automatic updates tried in this app run (``RemoteAutoUpdateLedger``).
    @ObservationIgnored private var autoUpdated = RemoteAutoUpdateLedger()

    /// The app's main-thread scheduler, passed by the composition root: every SSH machine's event
    /// batches run on it.
    @ObservationIgnored private let mainWork: MainWorkScheduler

    /// - Parameter mainWork: The app's ``MainWorkScheduler`` (AppServices passes the one it was built with).
    init(machines: MachineRegistry, bundleID: String?, mainWork: MainWorkScheduler) {
        self.machines = machines
        self.mainWork = mainWork
        paths = SSHPaths.standard(bundleID: bundleID)
        binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        installer = RemoteInstaller(paths: paths)
        peerForgets = SSHPeerForgets(cli: binary, environment: Self.environment)
    }

    /// Why SSH machines cannot connect in this build, or nil.
    var unavailableReason: String? {
        if policyDisabled { return RefusalStrings.turnedOffByOrganization }
        return binary == nil ? RemoteStrings.noClient : nil
    }

    /// Set while an administrator turned remote hosts off (`DisabledFeatures`).
    private(set) var policyDisabled = false
    /// Machines that were set to connect when the policy turned them off.
    private var reconnectWhenAllowed: Set<String> = []

    /// Turning remote hosts off disconnects every SSH machine, keeps its
    /// workspaces (their terminals show "Turned off by your organization")
    /// and leaves the remote daemon and its processes running. Turning it on
    /// again reconnects the machines that were connecting before.
    func applyPolicy(disabled: Bool) {
        guard disabled != policyDisabled else { return }
        policyDisabled = disabled
        for session in machines.ssh { session.daemon.policyBlock.set(disabled) }
        if disabled {
            reconnectWhenAllowed = Set(machines.ssh.filter(\.autoConnect).map(\.machineID))
            for session in machines.ssh { session.disconnect(keepAutoConnect: true) }
        } else {
            for session in machines.ssh where session.autoConnect && reconnectWhenAllowed.contains(session.machineID) { session.connect() }
            reconnectWhenAllowed = []
        }
    }

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
            // Live state only: restoring connects and prunes saved hosts,
            // which the launch snapshot's cached registry must not drive.
            for await records in ObservationStream({ () -> [SessionRecord] in
                let store = machines.local.store
                return store.personal.isLoaded && !store.isProvisional ? store.personal.sessions : []
            }) {
                self?.restore(records)
                self?.restoreSavedHosts(registered: records)
            }
        })
    }

    func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        for session in machines.ssh { session.close() }
    }

    private func wakeAll(_ wake: SSHConnectionMachine.Wake) {
        guard !policyDisabled else { return }
        for session in machines.ssh where session.autoConnect { session.wake(wake) }
    }

    /// Adds machines saved in the session registry that this run has not
    /// seen; those the user left connected connect again.
    private func restore(_ records: [SessionRecord]) {
        for record in records {
            guard let fields = record.transport.flatMap(Self.fields) else { continue }
            restore(fields)
        }
    }

    /// Adds the machine of a saved transport unless this run has it or the
    /// user forgot it; it connects when the user left it connected.
    func restore(_ fields: [String: String]) {
        guard let host = SSHHost(transportFields: fields), !forgotten.contains(host.machineID),
              machines.sshSession(host.machineID) == nil, let session = makeSession(host) else { return }
        session.autoConnect = fields["connect"] != "false"
        if policyDisabled {
            session.daemon.policyBlock.set(true)
            if session.autoConnect { reconnectWhenAllowed.insert(session.machineID) }
            return
        }
        if session.autoConnect { session.connect() }
    }

    // MARK: Connect, disconnect, forget

    /// Connects to `destination` (or reconnects the saved machine it names); `byPerson` as ``reconnect(_:byPerson:)``.
    @discardableResult
    func connect(destination text: String, session name: String?, binary: String? = nil, stateDir: String? = nil,
                 offerInstall: Bool, byPerson: Bool = true) throws -> SSHMachineSession {
        if let reason = unavailableReason { throw ActionFailure(message: reason) }
        let destination: SSHDestination
        do { destination = try SSHDestination(parsing: text) } catch { throw ActionFailure(message: RemoteStrings.invalidDestination(text, error)) }
        // SSH… with only a destination names the machine, not a new entry: a machine already in
        // the list for the same host, user and port is reused, never added twice (cx-k21v).
        if nonEmpty(name) == nil, nonEmpty(binary) == nil, nonEmpty(stateDir) == nil, let saved = existing(destination) {
            saved.autoConnect = true
            rememberHost(saved)
            saved.offersInstall = offerInstall
            if offerInstall { offerInstallWhenOld(saved) }
            reconnect(saved, byPerson: byPerson)
            logger.info("connect \(destination.description, privacy: .public): reusing \(saved.machineID, privacy: .public)")
            return saved
        }
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
        peerForgets.connected(host.machineID)
        // The same machine (route, session, state directory) with another
        // cmux-tui path: the old link goes and the record takes the new
        // path, so a connect never runs the old binary again (cx-vuvc).
        if let saved = machines.sshSession(host.machineID), saved.host != host {
            logger.info("\(host.destination.description, privacy: .public): cmux-tui path is now \(host.remoteBinary, privacy: .public)")
            saved.close()
            _ = machines.removeSSH(host.machineID)
        }
        let session = machines.sshSession(host.machineID) ?? makeSession(host)
        guard let session else { throw ActionFailure(message: RemoteStrings.noClient) }
        if !byPerson, session.waitsForUser { return session }
        // Saved now, before the first connect succeeds (no session id yet).
        session.autoConnect = true
        rememberHost(session)
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

    /// The machine in the list for `destination`'s host, user and port: the same user and port
    /// (a part left out matches only a saved entry that left it out too, so `host` never picks
    /// `root@host` or `host:2222`); host names compare without case. The default session wins.
    private func existing(_ destination: SSHDestination) -> SSHMachineSession? {
        let matches = machines.ssh.filter { session in
            let saved = session.host.destination
            return saved.host.caseInsensitiveCompare(destination.host) == .orderedSame
                && saved.user == destination.user && saved.port == destination.port
        }
        return matches.first { $0.host.session == RemoteSessionName.defaultName } ?? matches.first
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    func reconnect(_ session: SSHMachineSession, byPerson: Bool = true) {
        guard !policyDisabled, byPerson || !session.waitsForUser else { return } // only a person takes over a session in use (G5)
        // A retry gets a fresh error from the new attempt. Do not let the
        // recovery sheet copy the previous attempt while the link is working.
        session.lastError = nil
        switch session.linkStatus.reconnectStep(daemonConnected: session.daemon.startup == .connected, daemonFailed: session.daemonFailure != nil,
                                                retriesSpent: session.retriesSpent) {
        case .connect: session.connect()
        case .restart: session.restart()
        case .reconnectDaemon: session.reconnectDaemon()
        case .wake: session.wake(.user)
        case .newAttempt:
            session.beginConnectionAttempt()
            session.wake(.user)
        case .nothing: break
        }
    }

    func disconnect(_ session: SSHMachineSession) {
        session.disconnect()
        updateSavedHost(session)
        logger.info("disconnected \(session.host.destination.description, privacy: .public)")
    }

    /// Disconnects and removes the machine from the saved list, with its
    /// personal organization (order, groups, pins) in the home session.
    func forget(_ session: SSHMachineSession) async {
        await commitForget(hide(session))
    }

    /// Disconnects the machine and takes it out of this run at once; the
    /// writes wait for `commitForget` (the undo toast's end, `RemoteForgetUndo`).
    func hide(_ session: SSHMachineSession) -> SSHPeerForgets.Pending {
        forgotten.insert(session.machineID)
        let pending = peerForgets.hide(machineID: session.machineID, label: session.host.label, destination: session.host.destination,
                                       fields: Self.fields(Self.transport(session)) ?? [:],
                                       sessionID: session.daemon.identity?.sessionID ?? recordID(for: session.host))
        session.close()
        _ = machines.removeSSH(session.machineID)
        return pending
    }

    /// Undo of a hidden Forget: the machine comes back as it was saved, and
    /// connects again when it was set to connect.
    func unhide(_ pending: SSHPeerForgets.Pending) {
        forgotten.remove(pending.machineID)
        peerForgets.ended(pending)
        restore(pending.fields)
    }

    /// Writes a hidden Forget: the saved list entry and the home session's
    /// record with its personal organization go.
    func commitForget(_ pending: SSHPeerForgets.Pending) async {
        // A connect to the same machine while the toast showed took it back.
        peerForgets.ended(pending)
        guard stillForgotten(pending) else { return }
        forgetSavedHost(pending.machineID)
        if let sessionID = pending.sessionID, machines.local.supports(DaemonCapability.profiles.rawValue),
           let home = machines.local.connection {
            do {
                try await home.forgetSession(sessionID, force: true)
            } catch {
                logger.error("forget-session \(sessionID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        // Last, after every write: the peer goes only while the Forget still holds and no other
        // session reaches its route (checked again before each `host rm`).
        let route = pending.destination
        await peerForgets.removePeers(at: route) { [weak self] in
            guard let self else { return false }
            return stillForgotten(pending) && !machines.ssh.contains { SSHPeerForgets.sameRoute($0.host.destination, route) }
        }
    }

    /// A connect to the same machine (while the toast showed, or during a write) takes it back.
    private func stillForgotten(_ pending: SSHPeerForgets.Pending) -> Bool {
        forgotten.contains(pending.machineID) && machines.sshSession(pending.machineID) == nil
    }

    /// Settings > Devices removed the acpmux peer at `peer` (`[user@]host`): the SSH machines that
    /// reach the same route leave too, written at once (Remove for Good was confirmed already).
    func forgetMachines(reachingPeer peer: String) async {
        for session in machines.ssh where SSHPeerForgets.reaches(session.host.destination, peer: peer) {
            await forget(session)
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
        let session = SSHMachineSession(host: host, binary: binary, paths: paths, environment: Self.environment,
                                        mainWork: mainWork)
        session.daemon.workTracker = machines.local.workTracker
        session.daemon.onPaneNotReady = machines.local.onPaneNotReady
        session.daemon.paneNotReadyText = machines.local.paneNotReadyText
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
            for await level in ObservationStream({ session.flatMap { machines.compatibility(of: $0.daemon)?.level } }) {
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
        if status == .connected {
            session.lastError = nil
            // task-owner: one update check per connect; it installs only an older remote build
            Task { await updateIfOlder(session) }
        }
    }

    /// cx-3r9mt: on connect, an older remote build (`cmux-tui remote update-need`) gets this app's
    /// build, daemons handed over; any other answer or a failure leaves the machine as it was.
    func updateIfOlder(_ session: SSHMachineSession) async {
        guard !policyDisabled, let binary, case .installed? = await session.link.lastReport?.binary,
              let commit = await BundledCmuxTUI.commit(binary: binary) else { return }
        let tried = session.machineID + "|" + commit
        guard autoUpdated.mayTry(tried), !installing.contains(session.machineID),
              let checked = await session.host.updateCheck(binary: binary, environment: await Self.environment())
        else { return }
        let (probe, answer) = checked
        logger.info("update check for \(session.host.destination.description, privacy: .public): \(answer.need, privacy: .public) (\(answer.reason, privacy: .public))")
        guard answer.need == "older" else { session.updateOffered = false; return }
        // The keyed restart's rule (cx-3r9mt, hq-a3 2026-10-15): by itself only on an idle machine;
        // else the person decides (Update available, then Update).
        guard await agentDaemonIdleForUpdate(session) else {
            logger.info("update of \(session.host.destination.description, privacy: .public) offered: the machine is not idle")
            session.updateOffered = true
            autoUpdated.done(tried)
            return
        }
        autoUpdated.done(tried)
        do { try await install(session, automatic: probe.buildIdentity ?? "") } catch {
            autoUpdated.retry(tried, after: .seconds(120))
            logger.error("automatic update of \(session.host.destination.description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Install

    /// Installs the app's cmux-tui build on the machine and reconnects.
    /// `automatic` (cx-3r9mt): the remote `build_identity` the update was decided for; that build
    /// is skipped, a changed binary refused, and the link never shown as failed.
    func install(_ session: SSHMachineSession, automatic: String? = nil) async throws {
        if policyDisabled { throw ActionFailure(message: RefusalStrings.turnedOffByOrganization) }
        guard let binary else { throw ActionFailure(message: RemoteStrings.noClient) }
        guard let commit = await BundledCmuxTUI.commit(binary: binary) else { throw ActionFailure(message: RemoteStrings.noPinnedBuild) }
        let link = session.link, host = session.host
        let environment = await Self.environment()
        var report = await link.lastReport
        if report?.platform == nil { report = try? await link.probe(environment) }
        guard let platform = report?.platform else { throw ActionFailure(message: RemoteStrings.unsupportedPlatform(host.label)) }
        // The running daemon of this session, restarted onto the new build.
        let daemonPID = session.daemon.connection != nil ? session.daemon.identity?.pid : nil
        // One install and handoff per machine at a time (cx-3r9mt): this app's own, then the
        // machine's lock for every Mac (taken by the install script, given back below).
        guard installing.insert(session.machineID).inserted else { throw ActionFailure(message: RemoteStrings.installFailure(RemoteInstallError.remote(status: RemoteInstallError.busyStatus, message: "another install runs"))) }
        defer { installing.remove(session.machineID) }
        var lockedPlan: RemoteInstallPlan?
        if automatic == nil {
            await link.handle(.installStarted)
            session.lastError = nil
        }
        do {
            session.installPhase = .manifest
            var plan = try await installer.plan(commit: commit, treeKey: BundledCmuxTUI.treeKey(binary: binary), platform: platform,
                                                remoteBinary: host.remoteBinary)
            if let automatic {
                session.installPhase = nil
                guard plan.commit != automatic.lowercased() else {
                    logger.info("update of \(host.destination.description, privacy: .public) skipped: it already runs \(plan.commit, privacy: .public), the build this app installs")
                    return
                }
                plan.expectedRemoteIdentity = automatic
            }
            // Turned off while planning: refuse before the remote work starts (never mid-install).
            if policyDisabled { throw ActionFailure(message: RefusalStrings.turnedOffByOrganization) }
            lockedPlan = plan
            try await installer.install(plan, on: host, daemonPID: daemonPID, environment: environment) { phase in
                // task-owner: one main-actor hop per install step
                Task { @MainActor in session.installPhase = phase }
            }
            session.installPhase = nil
            logger.info("installed cmux-tui \(plan.commit, privacy: .public) on \(host.destination.description, privacy: .public)")
            session.updateOffered = false
            if automatic == nil { await link.handle(.installFinished(.success)) }
            // The machine's agent daemon still runs the replaced binary (cx-brq9m): hand it over to
            // the new one, keeping its agents, before the next chat needs it.
            await handOffAgentDaemonAfterInstall(session)
            await installer.releaseLock(plan, on: host, environment: environment)
            reconnect(session)
        } catch {
            if let lockedPlan { await installer.releaseLock(lockedPlan, on: host, environment: environment) }
            session.installPhase = nil
            if automatic != nil {
                // The machine keeps its old build and its link; the restart may have run, so link again.
                reconnect(session)
                throw error
            }
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
        var env = await TerminalEnvironment.instance.shared(base: base)()
        for key in TerminalEnvironment.instance.daemonIdentityKeys { if let value = base[key] { env[key] = value } }
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
