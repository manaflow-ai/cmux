import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// URL-level coverage for ``CmxAttachTicketInput`` across the two attach
/// payload grammars: the compact short-key form newer Macs put in the
/// pairing QR, and the legacy full-key form older Macs and stored fixtures
/// still produce. Both ride the same `cmux-ios://attach?v=1&payload=` URL.
@Suite struct CmxAttachTicketInputTests {
    private func makeTicket(authToken: String? = nil) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            macUserEmail: "user@example.com",
            macUserID: "user_mac_123",
            macPairingCompatibilityVersion: 1,
            macAppVersion: "0.64.15",
            macAppBuild: "42",
            routes: [
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.64.0.5", port: 8443)
                ),
            ],
            expiresAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 600),
            authToken: authToken
        )
    }

    private func attachURL(payload: Data, version: Int = CmxAttachTicket.currentVersion) -> String {
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cmux-ios://attach?v=\(version)&payload=\(encoded)"
    }

    @Test func decodesCompactPayloadAttachURL() throws {
        // New-phone-scans-new-QR.
        let ticket = try makeTicket(authToken: "minted-but-not-in-qr")
        let url = attachURL(payload: try CmxAttachTicketCompactCoder().encode(ticket))

        let decoded = try CmxAttachTicketInput.decode(url)
        #expect(decoded.macDeviceID == "mac-1")
        #expect(decoded.macUserEmail == nil)
        #expect(decoded.macUserID == "user_mac_123")
        #expect(decoded.macPairingCompatibilityVersion == 1)
        #expect(decoded.macAppVersion == "0.64.15")
        #expect(decoded.macAppBuild == "42")
        #expect(decoded.workspaceID == "")
        #expect(decoded.routes == ticket.routes)
        // The compact QR grammar intentionally drops the auth token (it
        // authorizes nothing), the display name (read post-handshake from
        // `mobile.host.status`), and inline expiry (the host-side ticket
        // reference owns expiry).
        #expect(decoded.authToken == nil)
        #expect(decoded.macDisplayName == nil)
        #expect(decoded.expiresAt == nil)
    }

    @Test func missingCompactCompatibilityDecodesAsUnknown() throws {
        let payload = """
        {"v":1,"d":"mac-1","u":"user_mac_123","r":[{"k":"tailscale","e":{"h":"100.64.0.5","p":8443}}]}
        """
        let decoded = try CmxAttachTicketInput.decode(
            attachURL(payload: Data(payload.utf8))
        )

        #expect(decoded.macPairingCompatibilityVersion == 0)
    }

    @Test func decodesLegacyFullKeyPayloadAttachURL() throws {
        // New-phone-scans-old-QR: the legacy grammar must keep decoding,
        // including its auth token.
        let ticket = try makeTicket(authToken: "legacy-token")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = attachURL(payload: try encoder.encode(ticket))

        let decoded = try CmxAttachTicketInput.decode(url)
        #expect(decoded.macDeviceID == "mac-1")
        #expect(decoded.routes == ticket.routes)
        #expect(decoded.authToken == "legacy-token")
    }

    @Test func missingLegacyCompatibilityDecodesAsUnknown() throws {
        let payload = """
        {"version":1,"workspaceID":"","terminalID":null,"macDeviceID":"mac-1",\
        "macDisplayName":null,"macUserID":"user_mac_123",\
        "routes":[{"id":"tailscale","kind":"tailscale",\
        "endpoint":{"type":"host_port","host":"100.64.0.5","port":8443},\
        "priority":0}]}
        """
        let decoded = try CmxAttachTicketInput.decode(
            attachURL(payload: Data(payload.utf8))
        )

        #expect(decoded.macPairingCompatibilityVersion == 0)
    }

    @Test func compactPayloadFailsLoudlyOnPreCompactDecoder() throws {
        // Old-phone-scans-new-QR: replicate the decode path shipped before
        // the compact grammar existed (plain Codable + iso8601) and prove it
        // throws instead of silently misreading the ticket.
        let ticket = try makeTicket()
        let payload = try CmxAttachTicketCompactCoder().encode(ticket)

        let preCompactDecoder = JSONDecoder()
        preCompactDecoder.dateDecodingStrategy = .iso8601
        #expect(throws: DecodingError.self) {
            try preCompactDecoder.decode(CmxAttachTicket.self, from: payload)
        }
    }

    @Test func staleQRCodesStillDecodeInBothGrammars() throws {
        // URL decoding is structural: host-side ticket references own expiry
        // for current QRs. Both a first-revision compact payload (explicit `e`
        // expiry long past) and a legacy full-key payload with a past
        // `expiresAt` must decode.
        let firstRevisionCompact = """
        {"v":1,"d":"mac-1","e":1000,"r":[{"i":"tailscale","k":"tailscale","e":{"t":"host_port","h":"100.64.0.5","p":8443}}]}
        """
        let compactDecoded = try CmxAttachTicketInput.decode(
            attachURL(payload: Data(firstRevisionCompact.utf8))
        )
        #expect(compactDecoded.macDeviceID == "mac-1")
        // The stale expiry is dropped outright on the compact path.
        #expect(compactDecoded.expiresAt == nil)
        #expect(!compactDecoded.isExpired(at: Date()))

        let legacy = """
        {"version":1,"workspaceID":"","terminalID":null,"macDeviceID":"mac-1",\
        "macDisplayName":null,"routes":[{"id":"tailscale","kind":"tailscale",\
        "endpoint":{"type":"host_port","host":"100.64.0.5","port":8443},\
        "priority":0}],"expiresAt":"2001-01-01T00:00:00Z"}
        """
        let legacyDecoded = try CmxAttachTicketInput.decode(
            attachURL(payload: Data(legacy.utf8))
        )
        #expect(legacyDecoded.macDeviceID == "mac-1")
        // Legacy payloads keep their expiry as data for token consumers.
        #expect(legacyDecoded.expiresAt == Date(timeIntervalSince1970: 978_307_200))
        #expect(legacyDecoded.isExpired(at: Date()))
    }

    @Test func garbagePayloadIsRejected() {
        let url = attachURL(payload: Data("definitely not json".utf8))
        #expect(throws: Error.self) {
            try CmxAttachTicketInput.decode(url)
        }
    }

    @Test func decodesMinimalPairingCodeURL() throws {
        // New-phone-scans-new-QR: the minimal v2 grammar (bare routes, no
        // payload blob) routes through the same input decoder as everything
        // else the scanner or a deep link can hand us.
        let decoded = try CmxAttachTicketInput.decode(
            "cmux-ios://attach?v=2&tr=ticket-ref-123&ub=user_mac_123&pc=1&av=0.64.15&ab=42&r=lawrences-mac.tail1234.ts.net:58465&r=100.64.0.5:58465"
        )
        #expect(decoded.workspaceID == "")
        #expect(decoded.macDeviceID == "")
        #expect(decoded.macDisplayName == nil)
        #expect(decoded.expiresAt == nil)
        #expect(decoded.ticketRef == "ticket-ref-123")
        #expect(decoded.authToken == nil)
        #expect(decoded.macUserEmail == nil)
        #expect(decoded.macUserID == "user_mac_123")
        #expect(decoded.macPairingCompatibilityVersion == 1)
        #expect(decoded.macAppVersion == "0.64.15")
        #expect(decoded.macAppBuild == "42")
        #expect(decoded.routes.count == 2)
        #expect(decoded.routes.map(\.id) == ["tailscale", "tailscale_2"])
        #expect(decoded.routes.allSatisfy { $0.kind == .tailscale })
    }

    @Test func minimalPairingCodeRejectsLoopback() {
        // A scanned v2 code must never point the phone at itself. The legacy
        // v1 payload grammar is intentionally NOT gated: the dev/simulator
        // auto-pair flow injects loopback attach URLs in that grammar.
        #expect(throws: MobileSyncPairingPayloadError.loopbackRouteRejected) {
            try CmxAttachTicketInput.decode("cmux-ios://attach?v=2&r=127.0.0.1:58465")
        }
        #expect(throws: MobileSyncPairingPayloadError.loopbackRouteRejected) {
            try CmxAttachTicketInput.decode("cmux-ios://attach?v=2&r=localhost:58465")
        }
    }

    @Test func legacyPairURLDecodesCompatibilityAsUnknown() throws {
        let payload = try MobileSyncPairingPayload(
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            host: "100.64.0.5",
            port: 8443,
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            transport: .tailscale
        )
        let decoded = try CmxAttachTicketInput.decode(payload.encodedURL().absoluteString)

        #expect(decoded.macPairingCompatibilityVersion == 0)
    }

    @Test func legacyLoopbackPayloadStillDecodesForDevInjection() throws {
        // The simulator/dev auto-pair path (CMUX_DOGFOOD_ATTACH_URL) builds a
        // legacy full-key payload with a loopback route; it must keep working.
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "dev-mac",
            macDisplayName: nil,
            routes: [
                try CmxAttachRoute(
                    id: "debug_loopback",
                    kind: .debugLoopback,
                    endpoint: .hostPort(host: "127.0.0.1", port: 58465)
                ),
            ],
            authToken: "dev-token"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try CmxAttachTicketInput.decode(attachURL(payload: try encoder.encode(ticket)))
        #expect(decoded.routes == ticket.routes)
        #expect(decoded.authToken == "dev-token")
    }

    @Test func decodesPairingCodeFromAnyChannelScheme() throws {
        // Cross-channel pairing from inside the app: the decoder accepts both
        // the release scheme (cmux-ios) and the dev scheme (cmux-ios-dev), so a
        // phone on either channel pairs from a QR minted by either channel.
        for scheme in CmxPairingURLScheme.all {
            let decoded = try CmxAttachTicketInput.decode(
                "\(scheme)://attach?v=2&r=100.64.0.5:58465"
            )
            #expect(decoded.routes.count == 1)
            #expect(decoded.routes.first?.kind == .tailscale)
        }
    }

    @Test func newerGrammarVersionThrowsUnrecognizedVersion() {
        // A QR minted by a newer cmux whose grammar version this build predates
        // (the field report: beta 1.0.2 scanned a v2 QR a newer Mac emitted).
        // It must surface distinctly so the UI says "update the app" instead of
        // the generic invalid-code copy. Use one past the build's known version
        // so the test tracks the constant rather than hardcoding 3.
        let newerVersion = CmxPairingQRCode.version + 1
        #expect(throws: MobileSyncPairingPayloadError.unrecognizedURLVersion(newerVersion)) {
            try CmxAttachTicketInput.decode(
                "cmux-ios://attach?v=\(newerVersion)&r=100.64.0.5:58465"
            )
        }
    }

    @Test func knownVersionDoesNotThrowUnrecognizedVersion() throws {
        // The current grammar version is not "newer", so it decodes normally
        // rather than tripping the unrecognized-version path.
        let decoded = try CmxAttachTicketInput.decode(
            "cmux-ios://attach?v=\(CmxPairingQRCode.version)&r=100.64.0.5:58465"
        )
        #expect(decoded.routes.count == 1)
    }
}
