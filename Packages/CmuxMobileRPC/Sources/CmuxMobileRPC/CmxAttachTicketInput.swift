public import CMUXMobileCore
import Foundation

/// Decodes a scanned or pasted `cmux-ios://` pairing/attach URL into a
/// validated ``CmxAttachTicket``.
public struct CmxAttachTicketInput {
    private init() {}

    /// Decode and validate a `cmux-ios://pair` or `cmux-ios://attach` URL.
    ///
    /// Attach tickets are validated structurally only; a scanned QR keeps
    /// working however long it sat on the Mac's screen (the host authorizes
    /// by Stack account, not ticket age). Only the ancient `cmux-ios://pair`
    /// grammar still enforces its own expiry.
    /// - Parameter rawValue: The scanned/pasted URL string.
    /// - Returns: A validated attach ticket.
    /// - Throws: `MobileSyncPairingPayloadError.invalidURL` or any ticket
    ///   validation error if the input is malformed, or
    ///   `MobileSyncPairingPayloadError.loopbackRouteRejected` for a v2
    ///   pairing code whose routes point at the phone itself.
    public static func decode(_ rawValue: String) throws -> CmxAttachTicket {
        guard let url = URL(string: rawValue) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        if url.scheme == "cmux-ios", url.host == "pair" {
            return try ticket(from: MobileSyncPairingPayload.decodeURL(url))
        }
        guard url.scheme == "cmux-ios",
              url.host == "attach",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        // The minimal v2 pairing-code grammar (bare Tailscale routes, loopback
        // rejected). v1 URLs carry a base64 JSON `payload` item instead.
        if CmxPairingQRCode.isPairingCodeURL(components) {
            return try CmxPairingQRCode.decode(components)
        }
        guard let encodedPayload = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              let data = base64URLDecode(encodedPayload) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        // Two payload grammars share the attach envelope: the compact
        // short-key form newer Macs put in the pairing QR (top-level "v"),
        // and the legacy full-key Codable form (top-level "version") that
        // older Macs, stored tickets, and UITest fixtures still produce.
        let ticket: CmxAttachTicket
        let compactCoder = CmxAttachTicketCompactCoder()
        if compactCoder.isCompactPayload(data) {
            ticket = try compactCoder.decode(data)
        } else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            ticket = try decoder.decode(CmxAttachTicket.self, from: data)
        }
        try ticket.validate()
        return ticket
    }

    private static func ticket(from payload: MobileSyncPairingPayload) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: payload.transport.rawValue,
            kind: payload.transport,
            endpoint: .hostPort(host: payload.host, port: payload.port)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: payload.macDeviceID,
            macDisplayName: payload.macDisplayName,
            routes: [route],
            expiresAt: payload.expiresAt
        )
        try ticket.validate()
        return ticket
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        return Data(base64Encoded: base64)
    }
}
