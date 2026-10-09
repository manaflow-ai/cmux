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
    /// Connect at launch (the user did not disconnect it). Saved in the
    /// session registry's transport.
    var autoConnect = true
    /// Offer to install when the next probe finds cmux-tui missing or too
    /// old (set by a user-initiated connect, cleared when offered).
    @ObservationIgnored var offersInstall = false
    @ObservationIgnored var onStatusChange: ((SSHMachineSession, SSHConnectionMachine.Status) -> Void)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

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
    }

    /// Ends the session for good (forget, quit).
    func close() {
        disconnect(keepAutoConnect: true)
        statusTask?.cancel()
    }

    private func linkStatusChanged(_ status: SSHConnectionMachine.Status) {
        guard linkStatus != status else { return }
        linkStatus = status
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
