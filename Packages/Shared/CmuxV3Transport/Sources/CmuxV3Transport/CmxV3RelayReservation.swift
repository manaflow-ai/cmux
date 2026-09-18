import CMUXMobileCore
import CmuxV3Native
import Foundation

/// Reserves configured relay addresses and returns target-complete directory
/// hints. Relay addresses are operator configuration, never user-provided
/// discovery data.
public enum CmxV3RelayReservation {
    public static func reserve(
        endpoint: NativeEndpoint,
        grants: any CmxV3GrantProviding,
        source: String,
        addresses: [String]
    ) async throws -> [String] {
        var reserved: [String] = []
        for address in addresses {
            guard let relayPeer = peerID(in: address),
                  let identity = try? CmxV3PeerIdentity(peerID: relayPeer, addresses: [address]),
                  let route = try? CmxAttachRoute(
                      id: "v3-relay-(relayPeer)",
                      kind: .v3,
                      endpoint: .v3Peer(identity),
                      priority: -20_000
                  ) else { continue }
            let request = CmxByteTransportRequest(
                route: route,
                expectedPeerDeviceID: nil,
                authorizationMode: .transportAdmission
            )
            guard let grant = try await grants.relayGrant(
                for: request,
                source: source,
                relay: relayPeer
            ) else { continue }
            let circuit = try await endpoint.reserve(
                address: address,
                grant: grant,
                operation: CmuxV3Native.Operation()
            )
            let target = "\(circuit)/p2p/\(source)"
            if target.utf8.count <= 2048 { reserved.append(target) }
        }
        return reserved
    }

    private static func peerID(in address: String) -> String? {
        let parts = address.split(separator: "/")
        guard let index = parts.lastIndex(of: "p2p"), index + 1 < parts.count else { return nil }
        let peer = String(parts[index + 1])
        return peer.isEmpty ? nil : peer
    }
}
