import Foundation
import Testing
@testable import CMUXMobileCore

private let compactIrohQRCoder = CmxAttachTicketCompactCoder()
private let compactIrohQREndpointID = String(repeating: "c", count: 64)

private func compactIrohQRExpiry() -> Date {
    Date(timeIntervalSince1970: 4_000_000_000)
}

private func compactIrohQRHostPortRoute() throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )
}

@Test func identityOnlyQRModeKeepsOnlyIrohIdentityAndRejectsTicketsWithoutIt() throws {
    let privateAddress = "100.64.1.2:49152"
    let relayURL = "https://relay.attacker.example/"
    let websocketURL = "wss://private.example/connect?token=secret"
    let iroh = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            identity: CmxIrohPeerIdentity(endpointID: compactIrohQREndpointID),
            pathHints: [
                CmxIrohPathHint(
                    kind: .directAddress,
                    value: privateAddress,
                    source: .tailscale,
                    privacyScope: .privateNetwork,
                    observedAt: compactIrohQRExpiry().addingTimeInterval(-60),
                    expiresAt: compactIrohQRExpiry(),
                    networkProfile: CmxIrohNetworkProfileKey(
                        source: .tailscale,
                        profileID: String(repeating: "a", count: 64)
                    )
                ),
                CmxIrohPathHint(
                    kind: .relayURL,
                    value: relayURL,
                    source: .native,
                    privacyScope: .publicInternet
                ),
            ]
        )
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: [
            compactIrohQRHostPortRoute(),
            iroh,
            CmxAttachRoute(
                id: "websocket",
                kind: .websocket,
                endpoint: .url(websocketURL)
            ),
        ]
    )

    let encoded = try compactIrohQRCoder.encode(
        ticket,
        routeDisclosureMode: .irohIdentityOnly
    )
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(json.contains(compactIrohQREndpointID))
    #expect(!json.contains(privateAddress))
    #expect(!json.contains(relayURL))
    #expect(!json.contains(websocketURL))
    #expect(!json.contains("\"h\""))
    #expect(!json.contains("\"u\":\"wss"))
    #expect(!json.contains("\"ph\""))

    let decoded = try compactIrohQRCoder.decode(encoded)
    #expect(decoded.routes.count == 1)
    #expect(decoded.routes.first?.id == iroh.id)
    guard case let .peer(identity, hints) = decoded.routes.first?.endpoint else {
        Issue.record("Expected identity-only Iroh route")
        return
    }
    #expect(identity.endpointID == compactIrohQREndpointID)
    #expect(hints.isEmpty)
    #expect(CmxPairingQRCode().encode(
        ticket,
        routeDisclosureMode: .irohIdentityOnly
    ) == nil)

    let tailscaleOnly = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: [compactIrohQRHostPortRoute()]
    )
    #expect(throws: CmxAttachTicketCompactCoderError.noRoutesForDisclosureMode(
        .irohIdentityOnly
    )) {
        _ = try compactIrohQRCoder.encode(
            tailscaleOnly,
            routeDisclosureMode: .irohIdentityOnly
        )
    }
}
