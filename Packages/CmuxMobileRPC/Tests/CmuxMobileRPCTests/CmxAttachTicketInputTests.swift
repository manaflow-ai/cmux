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
        #expect(decoded.macDisplayName == "Studio")
        #expect(decoded.workspaceID == "")
        #expect(decoded.routes == ticket.routes)
        #expect(decoded.expiresAt == ticket.expiresAt)
        // The compact QR grammar intentionally drops the auth token.
        #expect(decoded.authToken == nil)
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

    @Test func expiredCompactTicketIsRejected() throws {
        // Validation still runs on the compact path.
        let json = """
        {"v":1,"d":"mac-1","e":1000,"r":[{"i":"tailscale","k":"tailscale","e":{"t":"host_port","h":"100.64.0.5","p":8443}}]}
        """
        let url = attachURL(payload: Data(json.utf8))
        #expect(throws: CmxAttachTicketError.expired) {
            try CmxAttachTicketInput.decode(url)
        }
    }

    @Test func garbagePayloadIsRejected() {
        let url = attachURL(payload: Data("definitely not json".utf8))
        #expect(throws: Error.self) {
            try CmxAttachTicketInput.decode(url)
        }
    }
}
