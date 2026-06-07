public import CMUXMobileCore
import Foundation

/// Decodes a scanned or pasted `cmux-ios://` pairing/attach URL into a
/// validated ``CmxAttachTicket``.
public struct CmxAttachTicketInput {
    private init() {}

    /// Decode and validate a `cmux-ios://pair` or `cmux-ios://attach` URL.
    /// - Parameter rawValue: The scanned/pasted URL string.
    /// - Returns: A validated attach ticket.
    /// - Throws: `MobileSyncPairingPayloadError.invalidURL` or any ticket
    ///   validation error if the input is malformed or expired.
    public static func decode(_ rawValue: String) throws -> CmxAttachTicket {
        guard let url = URL(string: rawValue) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        if url.scheme == "cmux-ios", url.host == "pair" {
            return try ticket(from: MobileSyncPairingPayload.decodeURL(url))
        }
        guard url.scheme == "cmux-ios",
              url.host == "attach",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedPayload = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              let data = base64URLDecode(encodedPayload) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket = try decoder.decode(CmxAttachTicket.self, from: data)
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
