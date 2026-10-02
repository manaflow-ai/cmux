import Foundation
import Testing
@testable import CMUXMobileCore

private let compactIrohQRCoder = CmxAttachTicketCompactCoder()
private let compactIrohQREndpointID = String(repeating: "c", count: 64)
private let compactIrohQRTarget = CmxPairingURLScheme(
    iOSBundleIdentifier: "dev.cmux.app.beta"
)!

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

@Test func identityOnlyQRModeUsesPlainEndpointIDAndRejectsTicketsWithoutIt() throws {
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
    let pairingURL = try #require(CmxPairingQRCode().encode(
        ticket,
        routeDisclosureMode: .irohIdentityOnly,
        pairingURLScheme: compactIrohQRTarget
    ))
    // The Mac device id is deliberately part of the minimal grammar: the
    // decoded ticket must name the peer intent (`expectedPeerDeviceID`) the
    // irx transport requires before it will dial, and a fresh pairing has no
    // other source for it. It identifies but never authorizes; admission
    // stays the only authority.
    #expect(
        pairingURL
            == "\(compactIrohQRTarget.rawValue)://attach?v=3&i=\(compactIrohQREndpointID)&d=mac-1"
    )
    #expect(!pairingURL.contains("payload="))
    #expect(!pairingURL.contains(privateAddress))
    #expect(!pairingURL.contains(relayURL))
    #expect(!pairingURL.contains(websocketURL))

    let parsedURL = try #require(URL(string: pairingURL))
    let components = try #require(
        URLComponents(url: parsedURL, resolvingAgainstBaseURL: false)
    )
    let pairingDecoded = try CmxPairingQRCode().decode(components)
    let expectedPairingRoute = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            identity: CmxIrohPeerIdentity(endpointID: compactIrohQREndpointID),
            pathHints: []
        )
    )
    #expect(pairingDecoded.routes == [expectedPairingRoute])
    #expect(pairingDecoded.macDeviceID == "mac-1")
    #expect(pairingDecoded.macDisplayName == nil)
    #expect(pairingDecoded.macUserID == nil)
    // Endpoint-only v3 codes intentionally omit compatibility metadata. Keep
    // that absence distinguishable from an explicitly incompatible version.
    #expect(pairingDecoded.macPairingCompatibilityVersion == nil)
    #expect(pairingDecoded.macAppVersion == nil)
    #expect(pairingDecoded.macAppBuild == nil)
    #expect(pairingDecoded.expiresAt == nil)
    #expect(pairingDecoded.authToken == nil)

    let compactBase64 = encoded.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let beforeURL =
        "\(compactIrohQRTarget.rawValue)://attach?v=1&payload=\(compactBase64)"
    let beforeImage = try #require(CmxPairingQRBitmap().makeImage(payload: beforeURL))
    let afterImage = try #require(CmxPairingQRBitmap().makeImage(payload: pairingURL))
    let quietZone = CmxPairingQRBitmap.quietZoneModules * 2
    let beforeModules = beforeImage.width - quietZone
    let afterModules = afterImage.width - quietZone
    print(
        "iroh-pairing-qr: \(beforeURL.utf8.count)B/\(beforeModules)x\(beforeModules) -> "
            + "\(pairingURL.utf8.count)B/\(afterModules)x\(afterModules)"
    )
    #expect(pairingURL.utf8.count < beforeURL.utf8.count)
    #expect(afterModules < beforeModules)
    // 45 = one QR version above the endpoint-only 41: the `d` device-id field
    // buys working irx peer intent for one version step, still far below the
    // 57-module compact v1 payload.
    #expect(afterModules <= 45)

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

@Test func identityOnlyQRDecodeToleratesLegacyURLsWithoutDeviceID() throws {
    // Pre-`d` encoders mint exactly `v` + `i`. Those URLs must keep decoding
    // (empty device id), and a duplicated or unknown parameter still fails.
    let base = "\(compactIrohQRTarget.rawValue)://attach?v=3&i=\(compactIrohQREndpointID)"
    let legacy = try #require(URLComponents(string: base))
    let decoded = try CmxPairingQRCode().decode(legacy)
    #expect(decoded.macDeviceID.isEmpty)
    #expect(decoded.routes.count == 1)

    let doubledDevice = try #require(URLComponents(string: base + "&d=a&d=b"))
    #expect(throws: MobileSyncPairingPayloadError.invalidURL) {
        _ = try CmxPairingQRCode().decode(doubledDevice)
    }
    let unknownParameter = try #require(URLComponents(string: base + "&x=1"))
    #expect(throws: MobileSyncPairingPayloadError.invalidURL) {
        _ = try CmxPairingQRCode().decode(unknownParameter)
    }
}
