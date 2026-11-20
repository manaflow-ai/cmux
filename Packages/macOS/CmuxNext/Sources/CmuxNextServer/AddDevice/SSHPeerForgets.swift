public import CmuxNextRemote
public import Foundation

/// A written Forget of an SSH machine takes out the acpmux peer that enroll added for the same
/// route, so the machine leaves the agent list too (HQ #4877 break 8). It keeps the peer while a
/// Forget of that route still shows its Undo (an Undo brings the machine back and must find its
/// peer there), and asks again right before each `acp host rm`. The app's SSHService owns one.
@MainActor
public final class SSHPeerForgets {
    /// Removes the acpmux peers whose ssh `[user@]host` the predicate picks: by default the app's
    /// own cmux-tui (`acp host ls`, then `acp host rm` for each match, the predicate asked again
    /// right before each remove); tests replace it.
    public var remove: (((String) -> Bool) async -> Void)?
    /// Forgets still showing their Undo, each by its own token, so an older Forget's write never
    /// clears a newer one's mark.
    private var undoable: [UUID: (machineID: String, route: SSHDestination)] = [:]

    /// - Parameter cli: the app's own cmux-tui; nil (a build without it) removes no peer.
    public init(cli binary: URL?, environment: @escaping @Sendable () async -> [String: String]) {
        remove = binary.map { binary in
            let cli = HostCLI(binary: binary, environment: environment)
            return { matches in
                guard let data = await cli.json(["acp", "host", "ls", "--json"], label: "host ls") else { return }
                for peer in DeviceDirectory.sshPeers(data) where matches(peer.destination) {
                    _ = await cli.json(["acp", "host", "rm", peer.name, "--json"], label: "host rm")
                }
            }
        }
    }

    /// A Forget shown but not yet written: the machine is gone from this run, while the saved list
    /// and the home session still hold it.
    public struct Pending: Sendable {
        public let machineID: String
        /// This Forget's own mark among the ones whose Undo still shows.
        public let token = UUID()
        public let label: String
        /// Where it was reached: a written Forget also removes the acpmux peer at this route.
        public let destination: SSHDestination
        /// The registry transport, with its `connect` flag.
        public let fields: [String: String]
        public let sessionID: String?
    }

    /// A Forget of `machineID` at `destination` is hidden and shows its Undo: its route keeps its peer.
    public func hide(machineID: String, label: String, destination: SSHDestination, fields: [String: String], sessionID: String?) -> Pending {
        let pending = Pending(machineID: machineID, label: label, destination: destination, fields: fields, sessionID: sessionID)
        undoable[pending.token] = (machineID, destination)
        return pending
    }

    /// The Forget `pending` was undone or written: its Undo no longer shows.
    public func ended(_ pending: Pending) { undoable[pending.token] = nil }

    /// `machineID` connected again: no Forget of it holds its route any more.
    public func connected(_ machineID: String) { undoable = undoable.filter { $0.value.machineID != machineID } }

    /// Removes the peers at `route` while `holds` (the Forget still holds and no machine in the list
    /// reaches the route) and no Forget whose Undo still shows reaches it, asked before each remove.
    public func removePeers(at route: SSHDestination, while holds: @escaping @MainActor () -> Bool) async {
        await remove?({ [weak self] peer in
            guard let self, holds(), !undoable.values.contains(where: { Self.sameRoute($0.route, route) }) else { return false }
            return Self.reaches(route, peer: peer)
        })
    }

    /// Whether an SSH machine at `destination` and an acpmux peer whose `ssh://` URL dials `peer`
    /// (`[user@]host`, as enroll adds it for that machine) are the same route: the same host (any
    /// case) and the same user, and no ssh port on the machine (a peer URL's port is its daemon's,
    /// never ssh's, so a machine on another ssh port is never taken for it).
    public nonisolated static func reaches(_ destination: SSHDestination, peer: String) -> Bool {
        guard destination.port == nil, let target = try? SSHDestination(parsing: peer), target.port == nil else { return false }
        return sameRoute(destination, target)
    }

    /// The same host (any case), user and port.
    public nonisolated static func sameRoute(_ a: SSHDestination, _ b: SSHDestination) -> Bool {
        a.host.caseInsensitiveCompare(b.host) == .orderedSame && a.user == b.user && a.port == b.port
    }
}
