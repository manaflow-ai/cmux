import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import os

/// Keeps every Cloud machine on the app's own cmux-tui build with no click: each handshake of a
/// machine's daemon (the first connect and every reconnect, also one the app refused) offers it to
/// the app's one `DaemonUpdatePolicy` (`AppServices.daemonUpdates`) as a ``CloudMachineUpdateTarget``, in the same queue as
/// the acpmux ssh peers. The policy decides (another commit than the bundled build, never a newer
/// one; mid-turn from the first ask, with no wait for idle; backoff while the machine cannot
/// update; one target at a time; once per machine and build in its ledger; one notice per failure);
/// this type only feeds it Cloud machines. Their state shows in the machine header
/// (``CloudCreationRows``) from the app's `DaemonUpdateBoard`.
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
    /// Which handshakes are still to offer (``HandshakeFollower``).
    private var follower = HandshakeFollower()
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.machine-update")

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
            // The toggles too: a handshake left while they were off is offered once they turn on.
            let stream = ObservationStream({
                Snapshot(enabled: CloudTunables.updatesCloudMachines,
                         handshakes: machines.cloud.map { Handshake(machineID: $0.machineID, key: CloudMachineUpdates.handshake($0, machines: machines)) })
            })
            for await snapshot in stream {
                updates.note(snapshot)
            }
        }
    }

    /// One machine's handshake: its id, and the key of its daemon connection (nil: none yet).
    nonisolated struct Handshake: Sendable, Equatable {
        var machineID: String
        var key: String?
    }

    /// The Cloud machines' handshakes and the toggles, as the follower sees them at once.
    nonisolated struct Snapshot: Sendable, Equatable {
        var enabled: Bool
        var handshakes: [Handshake]
    }

    /// A key that changes with every new daemon connection of `session`: the connection object,
    /// the daemon process and boot; `refused` while the app refuses its daemon. Nil while none.
    static func handshake(_ session: CloudMachineSession, machines: MachineRegistry) -> String? {
        if let identity = session.daemon.identity, let connection = session.daemon.connection {
            return "\(ObjectIdentifier(connection)):\(identity.pid):\(identity.generation)"
        }
        return machines.compatibility(of: session.daemon)?.level == .incompatible ? "refused" : nil
    }

    private func note(_ snapshot: Snapshot) {
        for handshake in follower.due(snapshot) where offer(handshake.machineID) {
            follower.offered(handshake)
        }
    }

    /// Offers machine `machineID` to the shared policy unless the toggles are off or the app has
    /// no `cmux` client; false when it made no offer. The policy keeps one entry per machine, so an
    /// offer per handshake is safe.
    private func offer(_ machineID: String) -> Bool {
        guard let services, let target = Self.target(machineID, services: services) else { return false }
        // task-owner: returns once the policy queued the machine; the policy's drain owns the update
        Task { [policy = services.daemonUpdates.policy] in await policy.offer(target) }
        return true
    }

    /// A chat start on machine `machineID` that its older daemon refused (``AgentTabRemoteHost/updateMachine``):
    /// the machine is updated to the app's build now, at the front of the shared policy's queue (joining
    /// an update of it that already runs), and this returns once that turn ended. False when no turn ran:
    /// the toggles are off, the app has no `cmux` client, or the machine is gone. Same guarantees as the
    /// automatic update: `--to-bundled --if-older`, never a move back, terminals and chats keep running.
    static func updateNow(_ machineID: String, services: AppServices) async -> Bool {
        guard let target = target(machineID, services: services) else { return false }
        logger.info("cloud machine \(machineID, privacy: .public): a start was refused by its daemon; updating it before starting again")
        await services.daemonUpdates.policy.updateNow(target)
        return true
    }

    /// Machine `machineID` as the shared policy's target; nil while the toggles are off, the app has no
    /// `cmux` client, or the machine is gone.
    private static func target(_ machineID: String, services: AppServices) -> CloudMachineUpdateTarget? {
        guard CloudTunables.updatesCloudMachines, let session = services.machines.session(machineID),
              let binary = services.cloud.move.cli else { return nil }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        return CloudMachineUpdateTarget(machineID: machineID, displayName: session.machine.title,
                                        source: source(session, machines: services.machines, cli: cli, api: services.cloud.machineAPI,
                                                       logger: logger))
    }

    // MARK: The machine's side

    /// The live ``CloudMachineUpdateTarget/Source`` of `session`. Each step reads the session on
    /// the main actor; nothing holds it.
    static func source(_ session: CloudMachineSession, machines: MachineRegistry, cli: CloudMoveCLI, api: CloudAPIClient? = nil,
                       logger: Logger) -> CloudMachineUpdateTarget.Source {
        let machineID = session.machineID
        let binary = cli.binary
        return CloudMachineUpdateTarget.Source(
            daemon: { [weak session, weak machines] in await CloudMachineUpdates.daemon(of: session, machines: machines) },
            update: { [weak session] in
                guard let socket = await CloudMachineUpdates.socket(of: session) else {
                    return CloudMoveCLI.Answer(ok: false, errorCode: "machine_unreachable", error: "the machine is not connected")
                }
                logger.info("cloud machine \(machineID, privacy: .public): updating cmux-tui to the app's build")
                return try await cli.machineUpdate(socket: socket, toBundled: true, ifOlder: true)
            },
            reconnect: { [weak session] restarted in await session?.reconnectAfterUpdate(restarted: restarted) },
            legacy: { [weak session] build, judged in
                // Only the build this app pins for its own: a manifest of another build is not this app's.
                guard let api, await CloudMachineUpdates.allowsExec(session),
                      let pin = CloudLegacyMachineUpdate.pin(for: build.hash, besideCLI: binary),
                      let script = CloudLegacyMachineUpdate.script else { return nil }
                logger.info("cloud machine \(machineID, privacy: .public): too old to update in place; installing cmux-tui \(pin.commit, privacy: .public) through exec")
                // Only while it still runs the build `--if-older` judged older (checked under the
                // machine's upgrade lock): an update by another app meanwhile is never undone here.
                return await CloudLegacyMachineUpdate.run(pin: pin, script: script, expected: judged) { command, timeoutMs in
                    try await api.exec(machineID, command: command, timeoutMs: timeoutMs)
                }
            })
    }

    /// Whether the Cloud API runs commands on the machine of `session` (the legacy update's channel).
    private static func allowsExec(_ session: CloudMachineSession?) -> Bool {
        session?.machine.allows(.exec) == true
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

/// Which Cloud machine handshakes ``CloudMachineUpdates`` still has to offer: each new handshake
/// once. Only an offer that was made spends it: one left while the toggles are off, or while the
/// app has no `cmux` client, stays due. The toggles going off forget every offer, since the policy
/// may drop what it queued meanwhile: turned on again, every live handshake is offered once more
/// (the policy keeps one entry per machine and skips a machine already on the build). A machine
/// with no handshake (no connection, not refused) forgets its last, so its next one is new, also a
/// second refusal, whose key is the same.
nonisolated struct HandshakeFollower: Sendable {
    /// Each machine's last handshake offered.
    private(set) var spent: [String: String] = [:]

    /// The handshakes to offer now: none while the toggles are off (and every offer forgotten);
    /// else each that differs from its machine's last offered one. Forgets machines that are gone
    /// or have no handshake.
    mutating func due(_ snapshot: CloudMachineUpdates.Snapshot) -> [CloudMachineUpdates.Handshake] {
        guard snapshot.enabled else {
            spent = [:]
            return []
        }
        let present = Set(snapshot.handshakes.compactMap { $0.key == nil ? nil : $0.machineID })
        spent = spent.filter { present.contains($0.key) }
        return snapshot.handshakes.filter { $0.key != nil && spent[$0.machineID] != $0.key }
    }

    /// `handshake` was offered: not due again until its machine's handshake changes.
    mutating func offered(_ handshake: CloudMachineUpdates.Handshake) {
        spent[handshake.machineID] = handshake.key
    }
}
