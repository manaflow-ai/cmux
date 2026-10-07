import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Observation

/// One paired server whose Chief brain session the app shows
/// (`ServerReach`): its own tree and sidebar section, named after the
/// server. Over the `ssh` route the link is an `SSHMachineSession` (the
/// same carrier as SSH machines, attaching to the brain's daemon socket);
/// over the `unix` route (the server is this Mac) the daemon connects to
/// the brain's socket directly. Never offers to install anything: the
/// brain's binaries belong to its installer.
@Observable
final class ServerMachineSession {
    let reach: ServerReach
    var machineID: String { reach.machineID }
    var name: String { reach.name }
    let daemon: DaemonService
    /// The SSH carrier (route `ssh`), nil for a server on this Mac.
    @ObservationIgnored let link: SSHMachineSession?
    @ObservationIgnored let emptyWorkspaces: EmptyWorkspaceRepair
    /// This Mac's own daemon identity: a route that leads back to it is refused.
    @ObservationIgnored private let localIdentity: @MainActor () -> DaemonIdentity?
    /// Connect at launch: true until the user disconnects (kept in the registry).
    var autoConnect = true
    @ObservationIgnored private var started = false

    init(reach: ServerReach, binary: URL?, paths: SSHPaths, environment: @escaping @Sendable () async -> [String: String],
         localIdentity: @escaping @MainActor () -> DaemonIdentity?) {
        self.reach = reach
        self.localIdentity = localIdentity
        switch reach.route {
        case .ssh(let host):
            let link = binary.map { SSHMachineSession(host: host, binary: $0, paths: paths, environment: environment, machineID: reach.machineID) }
            self.link = link
            daemon = link?.daemon ?? DaemonService(machineID: reach.machineID)
        case .unix:
            link = nil
            daemon = DaemonService(machineID: reach.machineID)
        }
        emptyWorkspaces = link?.emptyWorkspaces ?? EmptyWorkspaceRepair(daemon: daemon)
    }

    /// Starts connecting; never blocks: an offline server shows its state in
    /// the sidebar while the daemon loop waits for an event.
    func connect() {
        autoConnect = true
        switch reach.route {
        case .ssh:
            if let link { link.connect() } else { daemon.store.markFailed(RemoteStrings.noClient) }
        case .unix(let path):
            guard !started else {
                daemon.retryWake.fire()
                return
            }
            started = true
            let localIdentity = localIdentity
            daemon.start(remote: { path }, admit: { identity in
                // The brain's daemon is its own session: never this Mac's home daemon.
                guard let local = localIdentity() else { return }
                if identity.generation == local.generation || (identity.sessionID != nil && identity.sessionID == local.sessionID) {
                    throw CloudLinkError.unsafeSocket(CloudAppLinks.localDaemonDetail)
                }
            })
        }
    }

    func wake() {
        if let link { link.wake(.user) } else { daemon.retryWake.fire() }
    }

    /// Ends the session for good (pairing removed, sign-out, quit).
    func close() {
        if let link {
            link.close()
        } else {
            daemon.shutdownConnection()
        }
        started = false
    }
}
