import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Observation

/// One SSH machine: its saved route, its link (`SSHMachineLink`), and the
/// daemon connection over the link socket. Like `CloudMachineSession`, the
/// machine's daemon is its own tree and sidebar section.
@Observable
final class SSHMachineSession {
    let host: SSHHost
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
    /// Why the machine's cmux-tui did not start: the daemon's error and the
    /// link's output (the remote error, for example a session db the daemon
    /// cannot open). Set when the first connection gives up after the SSH
    /// link came up at least once, cleared when the daemon connects or the
    /// link stops (cx-zdh8). Before the link comes up, SSH's own status
    /// says what is wrong.
    var daemonFailure: String?
    /// The SSH link came up since the last connect (ssh reached the machine).
    @ObservationIgnored private var linkReached = false
    @ObservationIgnored private var startupError: DaemonError?
    /// Connect at launch (the user did not disconnect it). Saved in the
    /// session registry's transport.
    var autoConnect = true
    /// Offer to install when the next probe finds cmux-tui missing or too
    /// old (set by a user-initiated connect, cleared when offered).
    @ObservationIgnored var offersInstall = false
    @ObservationIgnored var onStatusChange: ((SSHMachineSession, SSHConnectionMachine.Status) -> Void)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?

    init(host: SSHHost, binary: URL, paths: SSHPaths, environment: @escaping @Sendable () async -> [String: String],
         machineID: String? = nil) {
        self.host = host
        self.machineID = machineID ?? host.machineID
        daemon = DaemonService(machineID: self.machineID)
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
            for await startup in ObservationStream({ daemon.startup }) {
                guard case .unavailable(let error) = startup else {
                    self?.startupError = nil
                    self?.daemonFailure = nil
                    continue
                }
                self?.startupError = error
                await self?.updateDaemonFailure(link: link)
            }
        }
    }

    /// The daemon failure text, once both the daemon gave up and the link
    /// came up.
    private func updateDaemonFailure(link: SSHMachineLink) async {
        guard let error = startupError, linkReached else {
            daemonFailure = nil
            return
        }
        let output = await link.output()
        guard startupError == error, linkReached else { return }
        daemonFailure = Self.failureText(error.description, output: output)
    }

    /// The daemon's error, then the link's output when it adds to it.
    static func failureText(_ error: String, output: String?) -> String {
        guard let output = output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty, !error.contains(output) else { return error }
        return error + "\n" + output
    }

    /// Ends the session for good (forget, quit).
    func close() {
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
                Task { [weak self] in await self?.updateDaemonFailure(link: link) }
            }
        case .connecting, .failed: break
        case .offline, .authFailed, .hostKeyUntrusted, .unreachable, .needsInstall, .installing, .installFailed:
            linkReached = false
            daemonFailure = nil
        }
        onStatusChange?(self, status)
    }

    /// Starts connecting (or reconnecting after a disconnect).
    func connect() {
        autoConnect = true
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
        daemon.shutdownConnection()
        linkStatus = .offline
        let link = link
        // task-owner: teardown hop; stop() is idempotent
        Task { await link.stop() }
    }
}
