import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import os

/// Keeps every Cloud machine on the app's own cmux-tui build with no click: each handshake of a
/// machine's daemon (the first connect and every reconnect, also one the app refused) offers it to
/// the app's one `DaemonUpdatePolicy.shared` as a ``CloudMachineUpdateTarget``, in the same queue as
/// the acpmux ssh peers. The policy decides (another commit than the bundled build, never a newer
/// one; mid-turn from the first ask, with no wait for idle; backoff while the machine cannot
/// update; one target at a time; once per machine and build in its ledger; one notice per failure);
/// this type only feeds it Cloud machines. Their state shows in the machine header
/// (``CloudCreationRows``) from `DaemonUpdateBoard.shared`.
///
/// - Off with `cloud.updateMachines` (``CloudTunables``) or the policy's `agent.updatePeers`: no
///   offer, and a machine already queued reports no build, which the policy leaves alone.
/// - Update Machine (``CloudMachineUpdate``) reads neither the toggles nor the ledger: a click
///   always runs.
/// - The trigger lives only in the app and always installs the app's own pinned build; no CLI verb,
///   action argument or agent reaches it.
@MainActor
final class CloudMachineUpdates {
    private weak var services: AppServices?
    /// Each machine's last handshake seen (``handshake(_:machines:)``).
    private var seen: [String: String] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.machine-update")

    private init(services: AppServices) {
        self.services = services
    }

    /// Follows the app's Cloud machines until the app quits (``AppServices/startCloud()``).
    @discardableResult
    static func start(_ services: AppServices) -> Task<Void, Never> {
        let updates = CloudMachineUpdates(services: services)
        let machines = services.machines
        // task-owner: app lifetime; follows the Cloud machines' handshakes
        return Task { @MainActor in
            let stream = ObservationStream({
                machines.cloud.map { Handshake(machineID: $0.machineID, key: CloudMachineUpdates.handshake($0, machines: machines)) }
            })
            for await handshakes in stream {
                updates.note(handshakes)
            }
        }
    }

    /// One machine's handshake: its id, and the key of its daemon connection (nil: none yet).
    nonisolated struct Handshake: Sendable, Equatable {
        var machineID: String
        var key: String?
    }

    /// A key that changes with every new daemon connection of `session`: the connection object,
    /// the daemon process and boot; `refused` while the app refuses its daemon. Nil while none.
    static func handshake(_ session: CloudMachineSession, machines: MachineRegistry) -> String? {
        if let identity = session.daemon.identity, let connection = session.daemon.connection {
            return "\(ObjectIdentifier(connection)):\(identity.pid):\(identity.generation)"
        }
        return machines.compatibility(of: session.daemon)?.level == .incompatible ? "refused" : nil
    }

    private func note(_ handshakes: [Handshake]) {
        let present = Set(handshakes.map(\.machineID))
        seen = seen.filter { present.contains($0.key) }
        for handshake in handshakes {
            guard let key = handshake.key, seen[handshake.machineID] != key else { continue }
            seen[handshake.machineID] = key
            offer(handshake.machineID)
        }
    }

    /// Offers machine `machineID` to the shared policy unless the toggles are off or the app has
    /// no `cmux` client. The policy keeps one entry per machine, so an offer per handshake is safe.
    private func offer(_ machineID: String) {
        guard CloudTunables.updatesCloudMachines, let services,
              let session = services.machines.session(machineID), let binary = services.cloud.move.cli else { return }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        let target = CloudMachineUpdateTarget(machineID: machineID, displayName: session.machine.title,
                                              source: Self.source(session, machines: services.machines, cli: cli, logger: logger))
        // task-owner: returns once the policy queued the machine; the policy's drain owns the update
        Task { await DaemonUpdatePolicy.shared.offer(target) }
    }

    // MARK: The machine's side

    /// The live ``CloudMachineUpdateTarget/Source`` of `session`. Each step reads the session on
    /// the main actor; nothing holds it.
    static func source(_ session: CloudMachineSession, machines: MachineRegistry, cli: CloudMoveCLI,
                       logger: Logger) -> CloudMachineUpdateTarget.Source {
        let machineID = session.machineID
        return CloudMachineUpdateTarget.Source(
            daemon: { [weak session, weak machines] in await CloudMachineUpdates.daemon(of: session, machines: machines) },
            update: { [weak session] in
                guard let socket = await CloudMachineUpdates.socket(of: session) else {
                    return CloudMoveCLI.Answer(ok: false, errorCode: "machine_unreachable", error: "the machine is not connected")
                }
                logger.info("cloud machine \(machineID, privacy: .public): updating cmux-tui to the app's build")
                return try await cli.machineUpdate(socket: socket, toBundled: true)
            },
            reconnect: { [weak session] in await session?.reconnectAfterUpdate() })
    }

    /// The machine's daemon as the app sees it: connected (its build and level), refused
    /// (`incompatible`, no build), or nil.
    static func daemon(of session: CloudMachineSession?, machines: MachineRegistry?) -> CloudMachineUpdateTarget.Daemon? {
        guard let session, let machines else { return nil }
        let level = machines.compatibility(of: session.daemon)?.level
        if let identity = session.daemon.identity, session.daemon.connection != nil {
            return CloudMachineUpdateTarget.Daemon(build: identity.buildCommit, level: level ?? .current)
        }
        return level == .incompatible ? CloudMachineUpdateTarget.Daemon(build: nil, level: .incompatible) : nil
    }

    /// The machine daemon's socket as this Mac reaches it (what Update Machine passes). A refused
    /// daemon left no connection: the legacy link's socket can be asked again; an app link's is
    /// read without asking (its connection's second ask would end the link), and the carrier
    /// dials the machine again for the CLI's own connection.
    private static func socket(of session: CloudMachineSession?) async -> String? {
        guard let session else { return nil }
        if let connection = session.daemon.connection, let path = await connection.endpoint?.socketPath { return path }
        if let appLink = session.appLink { return await appLink.currentSocket }
        guard session.link != nil, let endpoint = session.daemon.remoteEndpoint else { return nil }
        return try? await endpoint().socketPath
    }
}
