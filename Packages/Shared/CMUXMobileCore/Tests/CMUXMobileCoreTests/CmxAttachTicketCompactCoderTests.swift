import Foundation
import Testing
@testable import CMUXMobileCore

/// Round-trip and cross-grammar coverage for ``CmxAttachTicketCompactCoder``.
///
/// The pairing QR moved from the legacy full-key `Codable` JSON to a compact
/// short-key grammar. These tests pin the compact encode shape (short keys,
/// dropped empties, no auth token, no display name, no expiry), prove
/// lossless round trips of what the grammar keeps, and pin the compatibility
/// matrix: a new decoder accepts the current grammar, the first compact
/// revision (extra `e`/`n` keys, explicit route ids and endpoint types), and
/// the legacy full-key grammar via the input router, while the legacy decoder
/// rejects compact payloads with a thrown error rather than a silently wrong
/// ticket.

private let compactCoder = CmxAttachTicketCompactCoder()
private let compactCanonicalEndpointID = String(repeating: "c", count: 64)

private func encodeLegacyCompatibility(_ ticket: CmxAttachTicket) throws -> Data {
    try compactCoder.encode(
        ticket,
        routeDisclosureMode: .legacyPrivateNetworkCompatibility
    )
}

private func wholeSecondFutureExpiry() -> Date {
    Date(timeIntervalSince1970: 4_000_000_000)
}

private func hostPortRoute(priority: Int = 0) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831),
        priority: priority
    )
}

private func legacyDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

@Test func compactEncodeUsesShortKeysAndNeverCarriesAuthTokenNameOrExpiry() throws {
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: "terminal-9",
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        macUserEmail: "user@example.com",
        macUserID: "user_mac_123",
        macPairingCompatibilityVersion: 1,
        macAppVersion: "0.64.15",
        macAppBuild: "42",
        routes: [try hostPortRoute(priority: 1)],
        expiresAt: wholeSecondFutureExpiry(),
        authToken: "ticket-secret"
    )

    let data = try encodeLegacyCompatibility(ticket)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(!json.contains("auth_token"))
    #expect(!json.contains("authToken"))
    #expect(!json.contains("ticket-secret"))
    #expect(!json.contains("workspaceID"))
    #expect(!json.contains("version"))
    #expect(json.contains("\"v\":1"))
    #expect(json.contains("\"w\":\"workspace-1\""))
    #expect(json.contains("\"d\":\"mac-1\""))
    #expect(!json.contains("user@example.com"))
    #expect(json.contains("\"u\":\"user_mac_123\""))
    #expect(json.contains("\"pc\":1"))
    #expect(json.contains("\"av\":\"0.64.15\""))
    #expect(json.contains("\"ab\":\"42\""))
    // The grammar no longer carries the display name or an expiry: the name
    // arrives post-handshake via `mobile.host.status`, and a pairing QR never
    // expires.
    #expect(!json.contains("Studio"))
    #expect(!json.contains("4000000000"))
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["n"] == nil)
    #expect(object["e"] == nil)
}

@Test func compactRoundTripsFullFieldTicketExceptDroppedQRFields() throws {
    let routes = [
        try hostPortRoute(priority: 2),
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: try CmxIrohPeerIdentity(endpointID: compactCanonicalEndpointID),
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .relayIdentifier,
                        value: "use1",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: "192.168.1.4:4242",
                        source: .lan,
                        privacyScope: .localNetwork,
                        observedAt: wholeSecondFutureExpiry().addingTimeInterval(-60),
                        expiresAt: wholeSecondFutureExpiry(),
                        networkProfile: CmxIrohNetworkProfileKey(
                            source: .lan,
                            profileID: String(repeating: "b", count: 64)
                        )
                    ),
                    try CmxIrohPathHint(
                        kind: .relayURL,
                        value: "https://relay.example",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                ]
            ),
            priority: 1
        ),
        try CmxAttachRoute(
            id: "ws",
            kind: .websocket,
            endpoint: .url("wss://example.com/attach")
        ),
    ]
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: "terminal-9",
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        macUserEmail: "user@example.com",
        macUserID: "user_mac_123",
        macPairingCompatibilityVersion: 1,
        macAppVersion: "0.64.15",
        macAppBuild: "42",
        routes: routes,
        expiresAt: wholeSecondFutureExpiry(),
        authToken: "ticket-secret"
    )

    let encoded = try encodeLegacyCompatibility(ticket)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(json.contains(compactCanonicalEndpointID))
    #expect(!json.contains("\"ph\""))
    #expect(!json.contains("\"rh\""))
    #expect(!json.contains("\"ru\""))
    #expect(!json.contains("\"da\""))
    #expect(!json.contains("192.168.1.4"))
    #expect(!json.contains("network_profile"))
    #expect(!json.contains("relay.example"))
    #expect(!json.contains("use1"))

    let decoded = try compactCoder.decode(encoded)

    #expect(decoded.version == ticket.version)
    #expect(decoded.workspaceID == ticket.workspaceID)
    #expect(decoded.terminalID == ticket.terminalID)
    #expect(decoded.macDeviceID == ticket.macDeviceID)
    #expect(decoded.macUserEmail == nil)
    #expect(decoded.macUserID == ticket.macUserID)
    #expect(decoded.macPairingCompatibilityVersion == ticket.macPairingCompatibilityVersion)
    #expect(decoded.macAppVersion == ticket.macAppVersion)
    #expect(decoded.macAppBuild == ticket.macAppBuild)
    #expect(decoded.routes.map(\.id) == ticket.routes.map(\.id))
    guard case let .peer(decodedIdentity, decodedHints) = decoded.routes[1].endpoint else {
        Issue.record("Expected compact Iroh peer route")
        return
    }
    #expect(decodedIdentity.endpointID == compactCanonicalEndpointID)
    #expect(decodedHints.isEmpty)
    #expect(decoded.routes[0] == ticket.routes[0])
    #expect(decoded.routes[2] == ticket.routes[2])
    // Dropped by design: the auth token never authorizes anything, the name
    // arrives via `mobile.host.status`, and a pairing QR never expires.
    #expect(decoded.authToken == nil)
    #expect(decoded.macDisplayName == nil)
    #expect(decoded.expiresAt == nil)
    #expect(!decoded.isExpired(at: .distantFuture))
}

@Test func compactDecodeKeepsLegacyEmailPayloadsWorking() throws {
    let legacyEmailPayload = """
    {"v":1,"d":"mac-1","u":"user@example.com","r":[{"k":"tailscale","e":{"h":"100.64.1.2","p":49831}}]}
    """

    let decoded = try compactCoder.decode(Data(legacyEmailPayload.utf8))

    #expect(decoded.macUserEmail == "user@example.com")
    #expect(decoded.macUserID == nil)
}

@Test func compactRoundTripsMacWidePairingTicketAndDropsEmptyFields() throws {
    // The shape the pairing window mints: Mac-wide (empty workspaceID), no
    // terminal scope.
    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: [try hostPortRoute()],
        expiresAt: wholeSecondFutureExpiry(),
        authToken: "ticket-secret"
    )

    let data = try encodeLegacyCompatibility(ticket)
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    // Empty workspaceID, nil terminalID, the display name, and the expiry
    // are all omitted.
    #expect(object["w"] == nil)
    #expect(object["t"] == nil)
    #expect(object["n"] == nil)
    #expect(object["e"] == nil)
    let route = try #require((object["r"] as? [[String: Any]])?.first)
    // priority 0 is the default and is omitted from the route, the id
    // "tailscale" matches what the decoder resynthesizes from the kind, and
    // the endpoint type is implied by `h` + `p`.
    #expect(route["p"] == nil)
    #expect(route["i"] == nil)
    let endpoint = try #require(route["e"] as? [String: Any])
    #expect(endpoint["t"] == nil)

    let decoded = try compactCoder.decode(data)
    #expect(decoded.workspaceID == "")
    #expect(decoded.terminalID == nil)
    #expect(decoded.macDisplayName == nil)
    #expect(decoded.routes == ticket.routes)
}

@Test func compactRoundTripsRepeatedKindAndCustomRouteIDs() throws {
    // First tailscale route gets the synthesized id "tailscale", the second
    // "tailscale_2" (both omitted on the wire); the custom "vpn-backup" id
    // differs from any synthesized id, so it rides verbatim.
    let routes = [
        try hostPortRoute(),
        try CmxAttachRoute(
            id: "tailscale_2",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.3", port: 49832)
        ),
        try CmxAttachRoute(
            id: "vpn-backup",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.4", port: 49833)
        ),
    ]
    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: routes
    )

    let data = try encodeLegacyCompatibility(ticket)
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let encodedRoutes = try #require(object["r"] as? [[String: Any]])
    #expect(encodedRoutes.count == 3)
    #expect(encodedRoutes[0]["i"] == nil)
    #expect(encodedRoutes[1]["i"] == nil)
    #expect(encodedRoutes[2]["i"] as? String == "vpn-backup")

    let decoded = try compactCoder.decode(data)
    #expect(decoded.routes == routes)
}

@Test func compactDecodeAcceptsFirstRevisionPayloadAndDropsExpiryAndName() throws {
    // A QR minted by the first compact revision: expiry under `e` (already in
    // the past), display name under `n`, explicit route `i`, and explicit
    // endpoint type `t`. It must keep pairing: the stale expiry and the name
    // are dropped, the explicit ids and types are honored.
    let firstRevision = Data("""
    {"d":"mac-1","e":1000,"n":"Studio","r":[{"e":{"h":"100.64.1.2","p":49831,"t":"host_port"},"i":"tailscale","k":"tailscale"}],"v":1}
    """.utf8)

    let decoded = try compactCoder.decode(firstRevision)
    #expect(decoded.macDeviceID == "mac-1")
    #expect(decoded.macDisplayName == nil)
    #expect(decoded.expiresAt == nil)
    #expect(!decoded.isExpired(at: .distantFuture))
    let expectedRoutes = [try hostPortRoute()]
    #expect(decoded.routes == expectedRoutes)
}

@Test func compactDecodeKeepsFirstRevisionIrohHintFieldsReadable() throws {
    let firstRevision = Data("""
    {"d":"mac-1","r":[{"e":{"da":["8.8.8.8:4242"],"i":"\(compactCanonicalEndpointID)","rh":"use1","ru":"https://relay.example/","t":"peer"},"i":"iroh","k":"iroh"}],"v":1}
    """.utf8)

    let decoded = try compactCoder.decode(firstRevision)
    guard case let .peer(identity, pathHints) = decoded.routes.first?.endpoint else {
        Issue.record("Expected legacy compact Iroh peer route")
        return
    }
    #expect(identity.endpointID == compactCanonicalEndpointID)
    #expect(pathHints.map(\.kind) == [.relayIdentifier, .directAddress, .relayURL])
    #expect(pathHints.first { $0.kind == .directAddress }?.isUsable(at: .distantPast) == false)
}

@Test func legacyDecoderRejectsCompactPayloadLoudly() throws {
    // Old-phone-scans-new-QR: the pre-compact decoder must throw (missing
    // "version" key), never silently produce a wrong ticket.
    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        routes: [try hostPortRoute()],
        expiresAt: wholeSecondFutureExpiry()
    )
    let compact = try encodeLegacyCompatibility(ticket)

    #expect(throws: DecodingError.self) {
        try legacyDecoder().decode(CmxAttachTicket.self, from: compact)
    }
}

@Test func compactDecoderRejectsLegacyPayload() throws {
    // The compact decoder is never handed a legacy payload in production
    // (the input router checks `isCompactPayload` first), but if it were it
    // must throw, not mis-decode.
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: [try hostPortRoute()],
        expiresAt: wholeSecondFutureExpiry()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacy = try encoder.encode(ticket)

    #expect(compactCoder.isCompactPayload(legacy) == false)
    #expect(throws: DecodingError.self) {
        try compactCoder.decode(legacy)
    }
}

@Test func compactPayloadDetectionDistinguishesGrammars() throws {
    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: [try hostPortRoute()],
        expiresAt: wholeSecondFutureExpiry()
    )
    let compact = try encodeLegacyCompatibility(ticket)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacy = try encoder.encode(ticket)

    #expect(compactCoder.isCompactPayload(compact))
    #expect(!compactCoder.isCompactPayload(legacy))
    #expect(!compactCoder.isCompactPayload(Data("not json".utf8)))
}

@Test func compactDecodeRejectsUnsupportedPayloadVersion() throws {
    // The decoded `v` must reach validation: a future compact grammar
    // revision that bumps the version has to fail loudly on today's phones,
    // not silently misdecode as a version-1 ticket.
    let futureVersion = Data("""
    {"v":2,"d":"mac-1","r":[{"k":"tailscale","e":{"h":"100.64.1.2","p":49831}}]}
    """.utf8)
    #expect(throws: CmxAttachTicketError.unsupportedVersion(2)) {
        try compactCoder.decode(futureVersion)
    }
}

@Test func compactDecodeRejectsUnknownRouteKindAndEndpointType() throws {
    let unknownKind = Data("""
    {"v":1,"d":"mac-1","e":4000000000,"r":[{"i":"x","k":"carrier-pigeon","e":{"t":"host_port","h":"100.64.1.2","p":49831}}]}
    """.utf8)
    #expect(throws: DecodingError.self) {
        try compactCoder.decode(unknownKind)
    }

    let unknownEndpoint = Data("""
    {"v":1,"d":"mac-1","e":4000000000,"r":[{"i":"tailscale","k":"tailscale","e":{"t":"smoke-signal"}}]}
    """.utf8)
    #expect(throws: DecodingError.self) {
        try compactCoder.decode(unknownEndpoint)
    }
}

@Test func compactPayloadIsSmallerThanLegacyPayload() throws {
    // The point of the grammar: the same Mac-wide pairing ticket (with the
    // auth token the store mints today) must shrink enough to drop QR
    // versions. Pin a ceiling near the 150-byte target so payload growth
    // shows up in review.
    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: UUID().uuidString,
        macDisplayName: "Lawrence's MacBook Pro",
        routes: [
            try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.102.73.120", port: 49831)
            ),
        ],
        expiresAt: wholeSecondFutureExpiry(),
        authToken: "3q2-7wDqzfQqzKpQ4XB8x1n0o5pYkz9jW2sT8uVbLwM"
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacy = try encoder.encode(ticket)
    let compact = try encodeLegacyCompatibility(ticket)

    #expect(compact.count < legacy.count)
    #expect(compact.count <= 150)
}
