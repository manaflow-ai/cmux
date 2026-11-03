import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar
import CmuxNextServer
import CmuxNextWorkspaceRepair
import Foundation
import Observation
import CmuxNextWakeups

/// One SSH machine: its saved route, its link (`SSHMachineLink`), and the
/// daemon connection over the link socket. Like `CloudMachineSession`, the
/// machine's daemon is its own tree and sidebar section.
@Observable
final class SSHMachineSession {
    struct DaemonFailure: Equatable {
        let attemptID: UInt64
        let error: String
    }

    struct DaemonObservationKey: Equatable {
        let startup: DaemonStartupState
        let attemptID: UInt64
    }

    static func daemonObservationKey(startup: DaemonStartupState, attemptID: UInt64) -> DaemonObservationKey {
        DaemonObservationKey(startup: startup, attemptID: attemptID)
    }

    /// Its route and name; Add Machine may rename it (`SSHHost.named`), never reroute it.
    var host: SSHHost
    /// The host's id, or the paired server's (`ServerMachineSession`).
    let machineID: String
    let daemon: DaemonService
    @ObservationIgnored let link: SSHMachineLink
    @ObservationIgnored let emptyWorkspaces: EmptyWorkspaceRepair
    /// The link's gate status (`SSHConnectionMachine`), mirrored from the actor.
    var linkStatus: SSHConnectionMachine.Status = .offline
    /// The install step in progress, for the header's detail.
    var installPhase: RemoteInstaller.Phase?
    /// The last install or connect failure worth showing.
    var lastError: String?
    /// cx-3r9mt: an older cmux-tui on a machine that is not idle: the sidebar says "Update
    /// available" and the person's Update installs it; the app never does it by itself.
    var updateOffered = false
    /// Why the machine's cmux-tui did not start: the daemon's error and the
    /// link's output (the remote error, for example a session db the daemon
    /// cannot open). Set when the first connection gives up after the SSH
    /// link came up at least once, cleared when the daemon connects or the
    /// link stops (cx-zdh8). Before the link comes up, SSH's own status
    /// says what is wrong.
    var daemonFailure: DaemonFailure?
    /// The SSH link came up since the last connect (ssh reached the machine).
    @ObservationIgnored private var linkReached = false
    @ObservationIgnored private var startupError: DaemonError?
    /// Connect at launch (the user did not disconnect it). Saved in the
    /// session registry's transport.
    var autoConnect = true
    /// Offer to install when the next probe finds cmux-tui missing or too
    /// old (set by a user-initiated connect, cleared when offered).
    @ObservationIgnored var offersInstall = false
    /// The window whose action connected it, where its "Connecting to…" row lists (#31490).
    @ObservationIgnored var connectingWindow: String?
    @ObservationIgnored var onStatusChange: ((SSHMachineSession, SSHConnectionMachine.Status) -> Void)?
    @ObservationIgnored var connectRecovery: SSHConnectRecovery?
    /// In use by another cmux daemon: only a person's Reconnect takes it over (G5). Retries spent: Offline (G4).
    var waitsForUser: Bool { link.waitsForUser }
    var retriesSpent: Bool { daemon.store.retriesSpent }
    /// Changes at the start of every user or automatic connection attempt, even when the
    /// transport and daemon report the same failure again.
    private(set) var connectionAttemptID: UInt64 = 0
    @ObservationIgnored var connectPresentationTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    /// - Parameter mainWork: The app's main-thread scheduler (the local daemon's), for the machine's event batches.
    init(host: SSHHost, binary: URL, paths: SSHPaths, environment: @escaping @Sendable () async -> [String: String],
         machineID: String? = nil, mainWork: MainWorkScheduler) {
        self.host = host
        self.machineID = machineID ?? host.machineID
        daemon = DaemonService(machineID: self.machineID, echoesPlacementShift: SidebarMirror.isLinked, mainWork: mainWork)
        // The actor reports each status change; only the latest matters.
        let (statuses, continuation) = AsyncStream.makeStream(of: SSHConnectionMachine.Status.self, bufferingPolicy: .bufferingNewest(8))
        link = SSHMachineLink(host: host, binary: binary, paths: paths, environment: environment) { continuation.yield($0) }
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
        statusTask = Task { [weak self] in
            for await status in statuses { self?.linkStatusChanged(status) }
        }
        let daemon = daemon, link = link
        // task-owner: follows the daemon's first-connect state for the session's life; cancelled in close()
        startupTask = Task { [weak self] in
            for await observation in ObservationStream({
                Self.daemonObservationKey(startup: daemon.startup, attemptID: self?.connectionAttemptID ?? 0)
            }) {
                guard let self, observation.attemptID == self.connectionAttemptID else { continue }
                let startup = observation.startup
                guard case .unavailable(let error) = startup else {
                    self.startupError = nil
                    self.daemonFailure = nil
                    continue
                }
                self.startupError = error
                await self.updateDaemonFailure(link: link, attemptID: observation.attemptID, error: error)
            }
        }
    }

    /// The daemon failure text, once both the daemon gave up and the link
    /// came up.
    private func updateDaemonFailure(link: SSHMachineLink, attemptID: UInt64, error: DaemonError) async {
        guard linkReached else {
            daemonFailure = nil
            return
        }
        let output = await link.output()
        guard startupError == error, connectionAttemptID == attemptID, linkReached else { return }
        daemonFailure = DaemonFailure(attemptID: attemptID, error: Self.failureText(error.description, output: output))
    }

    /// The daemon's error, then the link's output when it adds to it.
    static func failureText(_ error: String, output: String?) -> String {
        guard let output = output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty, !error.contains(output) else { return error }
        return error + "\n" + output
    }

    /// Ends the session for good (forget, quit).
    func close() {
        connectPresentationTask?.cancel()
        connectPresentationTask = nil
        connectRecovery?.stop()
        connectRecovery = nil
        disconnect(keepAutoConnect: true)
        statusTask?.cancel()
        startupTask?.cancel()
    }

    private func linkStatusChanged(_ status: SSHConnectionMachine.Status) {
        guard linkStatus != status else { return }
        linkStatus = status
        switch status {
        case .connected:
            if !linkReached {
                linkReached = true
                let link = link
                // task-owner: one actor hop to read the link's output
                Task { [weak self] in
                    guard let self, let error = self.startupError else { return }
                    await self.updateDaemonFailure(link: link, attemptID: self.connectionAttemptID, error: error)
                }
            }
        case .connecting, .reconnecting, .failed: break
        case .offline, .authFailed, .hostKeyUntrusted, .unreachable, .needsInstall, .installing, .installFailed:
            linkReached = false
            daemonFailure = nil
        }
        onStatusChange?(self, status)
    }

    /// Starts connecting (or reconnecting after a disconnect).
    func connect() {
        autoConnect = true
        beginConnectionAttempt()
        linkStatus = .connecting
        let link = link
        // task-owner: opens the gate first, so the daemon loop's first endpoint call can dial
        Task { [weak self] in
            await link.handle(.connect)
            guard let self, self.autoConnect, !self.daemon.policyBlock.isBlocked else { return }
            self.daemon.start(remote: {
                do {
                    return try await link.socketPath()
                } catch let error as SSHLinkError where error.waitsForUser {
                    // The next attempt waits for an event (DaemonStartup.shared.isPermanent).
                    throw DaemonError.endpointBlocked(error.description)
                }
            })
            // Already running (a reconnect): wake its wait.
            self.daemon.retryWake.fire()
        }
    }

    /// Stamps a new connection attempt before waking either the SSH link or the daemon.
    /// Clearing both state machines in this turn prevents an observation from replaying the
    /// previous attempt's failure while the new one is still opening.
    func beginConnectionAttempt() {
        connectionAttemptID &+= 1
        startupError = nil
        daemonFailure = nil
        // The link leaves a blocked failure only after an asynchronous user wake; the
        // mirror moves now, so the new attempt never shows the old failure. The link
        // then reports `.connecting` (already mirrored) and the retry's own result.
        if linkStatus.needsRecovery { linkStatusChanged(.connecting) }
        daemon.store.noteRetriesSpent(false)
        daemon.beginAttempt()
    }

    /// Disconnect then Connect, with a new retry budget: Reconnect once the retries are spent.
    func restart() {
        daemon.shutdownConnection()
        beginConnectionAttempt()
        linkStatus = .connecting
        // task-owner: teardown hop; cancelled by the next restart and by close(), so a closed session never connects
        restartTask?.cancel()
        restartTask = Task { [weak self, link] in
            await link.stop()
            guard !Task.isCancelled, let self, self.autoConnect else { return }
            self.connect()
        }
    }

    /// Reopens a daemon attempt without disturbing an already-connected SSH transport.
    func reconnectDaemon() {
        beginConnectionAttempt()
        daemon.retryWake.fire()
    }

    /// An event that may let a blocked attempt succeed: opens the gate,
    /// then wakes the daemon loop.
    func wake(_ wake: SSHConnectionMachine.Wake) {
        let link = link, retry = daemon.retryWake
        // task-owner: short actor hop; the retry fires after the gate opened
        Task {
            await link.handle(.wake(wake))
            retry.fire()
        }
    }

    func disconnect(keepAutoConnect: Bool = false) {
        if !keepAutoConnect { autoConnect = false }
        restartTask?.cancel()
        daemon.shutdownConnection()
        linkStatus = .offline
        let link = link
        // task-owner: teardown hop; stop() is idempotent
        Task { await link.stop() }
    }
}
