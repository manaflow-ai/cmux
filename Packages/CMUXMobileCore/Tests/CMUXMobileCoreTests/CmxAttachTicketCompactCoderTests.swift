import Foundation
import Testing
@testable import CMUXMobileCore

/// Round-trip and cross-grammar coverage for ``CmxAttachTicketCompactCoder``.
///
/// The pairing QR moved from the legacy full-key `Codable` JSON to a compact
/// short-key grammar. These tests pin the compact encode shape (short keys,
/// dropped empties, no auth token), prove lossless round trips, and pin the
/// compatibility matrix: a new decoder accepts both grammars, and the legacy
/// decoder rejects compact payloads with a thrown error rather than a
/// silently wrong ticket.

private let compactCoder = CmxAttachTicketCompactCoder()

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

@Test func compactEncodeUsesShortKeysAndNeverCarriesAuthToken() throws {
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: "terminal-9",
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        routes: [try hostPortRoute(priority: 1)],
        expiresAt: wholeSecondFutureExpiry(),
        authToken: "ticket-secret"
    )

    let data = try compactCoder.encode(ticket)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(!json.contains("auth_token"))
    #expect(!json.contains("authToken"))
    #expect(!json.contains("ticket-secret"))
    #expect(!json.contains("workspaceID"))
    #expect(!json.contains("version"))
    #expect(json.contains("\"v\":1"))
    #expect(json.contains("\"w\":\"workspace-1\""))
    #expect(json.contains("\"d\":\"mac-1\""))
    #expect(json.contains("\"e\":4000000000"))
}

@Test func compactRoundTripsFullFieldTicketExceptAuthToken() throws {
    let routes = [
        try hostPortRoute(priority: 2),
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                id: "peer-1",
                relayHint: "use1",
                directAddrs: ["192.168.1.4:4242"],
                relayURL: "https://relay.example"
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
        routes: routes,
        expiresAt: wholeSecondFutureExpiry(),
        authToken: "ticket-secret"
    )

    let decoded = try compactCoder.decode(
        compactCoder.encode(ticket)
    )

    #expect(decoded.version == ticket.version)
    #expect(decoded.workspaceID == ticket.workspaceID)
    #expect(decoded.terminalID == ticket.terminalID)
    #expect(decoded.macDeviceID == ticket.macDeviceID)
    #expect(decoded.macDisplayName == ticket.macDisplayName)
    #expect(decoded.routes == ticket.routes)
    #expect(decoded.expiresAt == ticket.expiresAt)
    // The auth token is dropped by design; it never authorizes anything.
    #expect(decoded.authToken == nil)
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

    let data = try compactCoder.encode(ticket)
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    // Empty workspaceID, nil terminalID, and nil display name are omitted.
    #expect(object["w"] == nil)
    #expect(object["t"] == nil)
    #expect(object["n"] == nil)
    // priority 0 is the default and is omitted from the route.
    let route = try #require((object["r"] as? [[String: Any]])?.first)
    #expect(route["p"] == nil)

    let decoded = try compactCoder.decode(data)
    #expect(decoded.workspaceID == "")
    #expect(decoded.terminalID == nil)
    #expect(decoded.macDisplayName == nil)
    #expect(decoded.routes == ticket.routes)
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
    let compact = try compactCoder.encode(ticket)

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
    let compact = try compactCoder.encode(ticket)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacy = try encoder.encode(ticket)

    #expect(compactCoder.isCompactPayload(compact))
    #expect(!compactCoder.isCompactPayload(legacy))
    #expect(!compactCoder.isCompactPayload(Data("not json".utf8)))
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
    // versions. Pin a generous ceiling so payload growth shows up in review.
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
    let compact = try compactCoder.encode(ticket)

    #expect(compact.count < legacy.count)
    #expect(compact.count <= 220)
}
