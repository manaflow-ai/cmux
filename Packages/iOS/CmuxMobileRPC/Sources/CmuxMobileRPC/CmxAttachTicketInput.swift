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
        // A future cmux release may register a new bundle-specific scheme that
        // this build has not classified yet. It is still recognizably a cmux
        // attach link, so preserve the actionable update path rather than
        // reporting an unrelated QR failure.
        if (url.host == "attach" || url.host == "pair"),
           let scheme = url.scheme?.lowercased(),
           scheme.hasPrefix("cmux-ios-"),
           CmxPairingURLScheme(rawValue: scheme) == nil {
            throw MobileSyncPairingPayloadError.unrecognizedURLVersion(
                CmxPairingQRCode.version + 1
            )
        }
        // Accept any classified channel's pairing scheme; cross-variant pairing
        // works when the user scans from inside the app. Official Macs emit the
        // canonical App Store scheme, while tagged DEV Macs retain exact-tag
        // routing for their development lane.
        if CmxPairingURLScheme(rawValue: url.scheme) != nil, url.host == "pair" {
            return try ticket(from: MobileSyncPairingPayload.decodeURL(url))
        }
        guard CmxPairingURLScheme(rawValue: url.scheme) != nil,
              url.host == "attach",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        // A cmux attach URL without a grammar marker is still recognizably a
        // cmux code, but this build cannot know which payload contract it uses.
        // Surface the actionable update path instead of asking the user to pick
        // another app or treating the code as an unrelated QR.
        guard let version = CmxPairingQRCode.attachURLVersion(components) else {
            throw MobileSyncPairingPayloadError.unrecognizedURLVersion(
                CmxPairingQRCode.version + 1
            )
        }
        // A QR minted by a newer cmux whose grammar version this build does not
        // understand. Distinguished from a malformed code so the user is told
        // to update the app instead of seeing the generic "not valid" copy (the
        // real field report: beta 1.0.2 predated the v2 QR a newer Mac emitted).
        if version > CmxPairingQRCode.version {
            throw MobileSyncPairingPayloadError.unrecognizedURLVersion(version)
        }
        // The plain pairing grammars: v2 carries bare Tailscale routes and v3
        // carries one Iroh EndpointID. v1 carries a base64 JSON payload.
        if CmxPairingQRCode().isPairingCodeURL(components) {
            return try CmxPairingQRCode().decode(components)
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
        let normalizedTicket = try ticket.withUnknownCompatibilityVersionForPairingURL()
        try normalizedTicket.validate()
        return normalizedTicket
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
            macPairingCompatibilityVersion: 0,
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

private extension CmxAttachTicket {
    func withUnknownCompatibilityVersionForPairingURL() throws -> CmxAttachTicket {
        guard macPairingCompatibilityVersion == nil else {
            return self
        }
        return try CmxAttachTicket(
            version: version,
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: 0,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }
}
