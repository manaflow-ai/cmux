import Foundation

/// The acpmux peers this Mac's daemon mirrors and whether each is reachable now: `_acpmux/peers`
/// on the daemon's socket. The daemon answers from what it holds (no peer is asked), so a slow or
/// down machine never slows the call; the deadline bounds a stuck daemon.
public nonisolated struct AcpmuxPeerList: Sendable {
    /// One peer as the daemon lists it.
    public struct Peer: Hashable, Sendable {
        /// The peer's acpmux name (`huge-blue`), the `peer` its mirrored sessions carry.
        public let name: String
        /// The daemon's link to it is up.
        public let connected: Bool

        public init(name: String, connected: Bool) {
            self.name = name
            self.connected = connected
        }
    }

    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    @concurrent public func peers(deadline: Duration = .seconds(2)) async throws -> [Peer] {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/peers", deadline: deadline)
        return Self.peers(result)
    }

    /// The peers of a `_acpmux/peers` answer (`{peers: [{name, connected}]}`).
    static func peers(_ result: [String: Any]) -> [Peer] {
        (result["peers"] as? [[String: Any]] ?? []).compactMap { peer in
            guard let name = peer["name"] as? String, !name.isEmpty else { return nil }
            return Peer(name: name, connected: peer["connected"] as? Bool ?? false)
        }
    }
}
