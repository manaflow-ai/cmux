public import CMUXMobileCore
import Foundation

/// Decodes a scanned or pasted `cmux-ios://` pairing/attach URL into a
/// validated ``CmxAttachTicket``.
public struct CmxAttachTicketInput {
    private init() {}

    /// Decode and validate a `cmux-ios://pair` or `cmux-ios://attach` URL.
    /// - Parameter rawValue: The scanned/pasted URL string.
    /// - Returns: A validated attach ticket.
    /// - Throws: `MobileSyncPairingPayloadError.invalidURL` for malformed
    ///   input, `MobileSyncPairingPayloadError.unsupportedPayloadFormat` /
    ///   `.unsupportedVersion` (or `CmxAttachTicketError.unsupportedVersion`)
    ///   when the payload is a cmux pairing payload in a format this build does
    ///   not speak, or any ticket validation error (e.g. expired).
    public static func decode(_ rawValue: String) throws -> CmxAttachTicket {
        guard let url = URL(string: rawValue) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        if url.scheme == "cmux-ios", url.host == "pair" {
            do {
                return try ticket(from: MobileSyncPairingPayload.decodeURL(url))
            } catch let error as DecodingError {
                // The payload didn't fit the pair grammar this build speaks. If
                // it still names a format version, surface "unsupported format"
                // instead of an opaque decode failure, so the user is told to
                // update rather than to uselessly rescan the same code.
                if let probed = formatProbeError(
                    payloadData: payloadData(of: url),
                    currentVersion: MobileSyncPairingPayload.currentVersion,
                    versionQueryItem: queryItem(of: url, named: "v")
                ) {
                    throw probed
                }
                throw error
            }
        }
        guard url.scheme == "cmux-ios",
              url.host == "attach",
              let data = payloadData(of: url) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket: CmxAttachTicket
        do {
            ticket = try decoder.decode(CmxAttachTicket.self, from: data)
        } catch let error as DecodingError {
            if let probed = formatProbeError(
                payloadData: data,
                currentVersion: CmxAttachTicket.currentVersion,
                versionQueryItem: queryItem(of: url, named: "v")
            ) {
                throw probed
            }
            throw error
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

    /// The base64url-decoded `payload` query item of a pairing URL, when present.
    private static func payloadData(of url: URL) -> Data? {
        guard let encodedPayload = queryItem(of: url, named: "payload") else {
            return nil
        }
        return base64URLDecode(encodedPayload)
    }

    private static func queryItem(of url: URL, named name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    /// Probes an undecodable payload for a cmux format/version marker.
    ///
    /// Called only after the grammar this build speaks failed to decode the
    /// payload, so any marker found means "a cmux payload from a build speaking
    /// a different format", not garbage:
    /// - a top-level `"v"` key is the compact short-key grammar newer Macs put
    ///   in the pairing QR (https://github.com/manaflow-ai/cmux/pull/5727); this
    ///   build has no compact decoder, so it is by definition a newer format.
    ///   Once a compact decoder lands, payloads it understands decode before
    ///   this probe runs and only genuinely newer compact versions reach it.
    /// - a top-level `"version"` key naming a version other than
    ///   `currentVersion` is the known long-key grammar at a version this build
    ///   does not speak.
    /// - with no readable payload at all, the URL's `v` query item is the last
    ///   marker (the Mac stamps the payload version there).
    ///
    /// - Returns: The typed unsupported-format error to throw, or `nil` when no
    ///   marker was found (the payload really is unreadable garbage).
    private static func formatProbeError(
        payloadData: Data?,
        currentVersion: Int,
        versionQueryItem: String?
    ) -> (any Error)? {
        if let payloadData,
           let object = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] {
            if let compactVersion = object["v"] as? Int {
                return MobileSyncPairingPayloadError.unsupportedPayloadFormat(compactVersion)
            }
            if let version = object["version"] as? Int, version != currentVersion {
                return MobileSyncPairingPayloadError.unsupportedVersion(version)
            }
            return nil
        }
        if let versionQueryItem, let version = Int(versionQueryItem), version != currentVersion {
            return MobileSyncPairingPayloadError.unsupportedVersion(version)
        }
        return nil
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
