import CmuxCloud
import Testing

@Suite("team network tunnel routes")
struct TeamNetworkTunnelTests {
    private func payload(includeNetworks: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "tunnelId": "tunnel-1",
            "provider": "freestyle",
            "deviceFingerprint": "device-1",
            "clientConfig": "[Interface]\nPrivateKey =\n[Peer]\n",
            "clientPublicKey": "client",
            "serverPublicKey": "server",
            "endpointPort": 51820,
            "network": ["id": "home", "cidr": "10.20.0.0/24", "cidrV6": "fd20::/64"]
        ]
        if includeNetworks {
            payload["networks"] = [
                ["id": "home", "cidr": "10.20.0.0/24", "cidrV6": "fd20::/64", "scope": "user"],
                ["id": "team", "cidr": "10.30.0.0/24", "cidrV6": "fd30::/64", "scope": "team"]
            ]
        }
        return payload
    }

    @Test("decodes home and team CIDRs into AllowedIPs")
    func decodesAllNetworkRoutes() throws {
        let endpoint = try VMClient.decodeTunnelEndpoint(payload(includeNetworks: true))
        #expect(endpoint.networkCidrs == ["10.20.0.0/24", "fd20::/64", "10.30.0.0/24", "fd30::/64"])
        let config = try VMTunnelManager.completedConfig(
            endpoint.clientConfig,
            privateKey: "private",
            allowedIPs: endpoint.networkCidrs
        )
        #expect(config.contains("10.20.0.0/24"))
        #expect(config.contains("10.30.0.0/24"))
        #expect(config.contains("fd30::/64"))
    }

    @Test("falls back to the legacy network fields")
    func fallsBackToLegacyNetwork() throws {
        let endpoint = try VMClient.decodeTunnelEndpoint(payload(includeNetworks: false))
        #expect(endpoint.networkCidrs == ["10.20.0.0/24", "fd20::/64"])
    }
}
