import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxLegacyPrivateNetworkPairingCodeTests {
    @Test func encodesTokenlessTailscaleOnlyFullKeyPayload() throws {
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 58_465),
            priority: 10
        )
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            ),
            priority: 0
        )
        let sourceExpiry = Date(timeIntervalSince1970: 1_800_000_000)
        let ticket = try CmxAttachTicket(
            version: CmxAttachTicket.currentVersion,
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Mac",
            macUserEmail: "private@example.com",
            macUserID: "opaque-user-id",
            macPairingCompatibilityVersion: 1,
            macAppVersion: "1.0",
            macAppBuild: "100",
            routes: [iroh, tailscale],
            expiresAt: sourceExpiry,
            authToken: "secret"
        )

        let encodedURL = try CmxLegacyPrivateNetworkPairingCode().encode(ticket)
        let url = try #require(encodedURL)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encoded = try #require(
            components.queryItems?.first(where: { $0.name == "payload" })?.value
        )
        let data = try #require(Self.decodeBase64URL(encoded))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CmxAttachTicket.self, from: data)

        #expect(decoded.routes == [tailscale])
        #expect(decoded.authToken == nil)
        #expect(decoded.macUserEmail == nil)
        #expect(decoded.macUserID == "opaque-user-id")
        #expect(try #require(decoded.expiresAt) > sourceExpiry.addingTimeInterval(365 * 24 * 60 * 60))
    }

    @Test func returnsNilWithoutTailscaleRoute() throws {
        let ticket = try CmxAttachTicket(
            version: CmxAttachTicket.currentVersion,
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Mac",
            macUserEmail: nil,
            macUserID: "opaque-user-id",
            routes: [
                try CmxAttachRoute(
                    id: "iroh",
                    kind: .iroh,
                    endpoint: .peer(
                        identity: CmxIrohPeerIdentity(
                            endpointID: String(repeating: "b", count: 64)
                        ),
                        pathHints: []
                    ),
                    priority: 0
                ),
            ],
            expiresAt: nil,
            authToken: nil
        )

        #expect(try CmxLegacyPrivateNetworkPairingCode().encode(ticket) == nil)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }
}
