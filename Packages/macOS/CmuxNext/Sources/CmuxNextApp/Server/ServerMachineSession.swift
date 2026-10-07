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

    /// The app's own bundled `cmux` (overlay route bridge), nil when missing.
    @ObservationIgnored private let cli: URL?

    init(reach: ServerReach, binary: URL?, paths: SSHPaths, environment: @escaping @Sendable () async -> [String: String],
         localIdentity: @escaping @MainActor () -> DaemonIdentity?, cli: URL? = nil) {
        self.reach = reach
        self.cli = cli
        self.localIdentity = localIdentity
        switch reach.route {
        case .ssh(let host):
            let link = binary.map { SSHMachineSession(host: host, binary: $0, paths: paths, environment: environment, machineID: reach.machineID) }
            self.link = link
            daemon = link?.daemon ?? DaemonService(machineID: reach.machineID)
        case .unix, .overlay:
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
            // Wait for the home daemon's identity (ServerReachService connects again then).
            guard localIdentity() != nil else { return }
            guard !started else {
                daemon.retryWake.fire()
                return
            }
            started = true
            let localIdentity = localIdentity
            daemon.start(remote: { path }, admit: { identity in
                // The brain's daemon is its own session, never this Mac's home daemon (fails closed).
                try CloudAppLinks.checkNotLocal(remote: identity, local: localIdentity())
            })
        case .overlay(let linkSocket):
            guard localIdentity() != nil else { return }
            guard !started else {
                daemon.retryWake.fire()
                return
            }
            started = true
            let localIdentity = localIdentity
            guard let cli else {
                daemon.store.markFailed(RemoteStrings.noClient)
                return
            }
            // Each connection runs the bundled `cmux link dial` for the
            // server's owner session; the server refuses anyone but its owner.
            let bridge = DaemonBridge(executable: cli.path, arguments: reach.dialArguments(linkSocket: linkSocket))
            daemon.start(remote: { linkSocket }, bridge: bridge, admit: { identity in
                try CloudAppLinks.checkNotLocal(remote: identity, local: localIdentity())
            })
        }
    }

    func wake() {
        if let link { link.wake(.user) } else { daemon.retryWake.fire() }
    }

    /// Drops the connection but keeps the session listed (policy off).
    func disconnect() {
        if let link { link.disconnect(keepAutoConnect: true) } else { daemon.shutdownConnection() }
        started = false
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
