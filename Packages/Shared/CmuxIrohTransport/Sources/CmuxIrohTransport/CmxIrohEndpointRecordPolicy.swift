public import Foundation
public import IrohLib

/// A parsed, signature-verified endpoint record accepted by local policy.
public struct CmxIrohVerifiedEndpointRecord: Equatable, Sendable {
    /// Canonical 64-character lowercase hex endpoint id that signed the record.
    public let endpointID: String
    /// Relay URLs named by the record, in record order.
    public let relayURLs: [String]
    /// Direct `ip:port` addresses named by the record, in record order.
    public let directAddresses: [String]
    /// The record's signing time.
    public let signedAt: Date
    /// The exact signed-packet bytes, suitable for handing back to iroh.
    public let blob: Data
}

/// Local acceptance policy for pkarr endpoint records.
///
/// Rust verifies the ed25519 signature and the endpoint-id match again before
/// magicsock merges a record, so this policy is not the integrity boundary.
/// It owns what Rust deliberately does not decide for us: record freshness
/// (bounded `signedAt` age) and the managed-relay allowlist, mirroring the
/// catalog/saved-set trust rule the broker applies in `web/services/relay/report.ts`.
/// A record naming any relay outside the allowlist is dropped whole, because
/// the signature covers the full packet and a partial rewrite would break it.
public enum CmxIrohEndpointRecordPolicy {
    /// The maximum accepted age of a record's signing time. Matches the
    /// broker-hint freshness ceiling (`CmxIrohPathHint.maximumPrivateHintTTL`).
    public static let maximumRecordAge: TimeInterval = 60 * 60

    /// Tolerated forward clock skew on a record's signing time.
    public static let maximumFutureSkew: TimeInterval = 5 * 60

    /// Parses and verifies one record blob, applying local policy.
    ///
    /// - Parameters:
    ///   - blob: The pkarr signed-packet bytes.
    ///   - endpointID: The canonical hex endpoint id the caller asked for,
    ///     or nil to accept the record's own signer (publish side).
    ///   - allowedRelayURLs: Exact relay origins permitted by the active
    ///     managed catalog, custom profile, or debug override.
    ///   - now: The evaluation time.
    /// - Returns: The verified record, or nil when the blob is malformed,
    ///   badly signed, stale, for another endpoint, or names a relay outside
    ///   the allowlist.
    public static func acceptableRecord(
        blob: Data,
        endpointID: String?,
        allowedRelayURLs: Set<String>,
        now: Date = Date()
    ) -> CmxIrohVerifiedEndpointRecord? {
        guard let summary = try? parseEndpointRecord(bytes: blob) else {
            return nil
        }
        let recordEndpointID = Self.canonicalEndpointID(summary.endpointId)
        if let endpointID, recordEndpointID != endpointID.lowercased() {
            return nil
        }
        let signedAt = Date(
            timeIntervalSince1970: TimeInterval(summary.lastUpdated) / 1_000_000
        )
        guard signedAt <= now.addingTimeInterval(maximumFutureSkew),
              signedAt >= now.addingTimeInterval(-maximumRecordAge) else {
            return nil
        }
        guard summary.relayUrls.allSatisfy({
            Self.isAllowedRelayURL($0, allowedRelayURLs: allowedRelayURLs)
        }) else {
            return nil
        }
        return CmxIrohVerifiedEndpointRecord(
            endpointID: recordEndpointID,
            relayURLs: summary.relayUrls,
            directAddresses: summary.directAddrs,
            signedAt: signedAt,
            blob: blob
        )
    }

    /// The canonical lowercase-hex form of an endpoint id.
    ///
    /// Pure-Swift nibble table, not `String(format:)`: this runs on every
    /// resolve and for every broker-fetched record, and per-byte Foundation
    /// format calls are a known allocation hazard on concurrent hot paths.
    public static func canonicalEndpointID(_ endpointID: EndpointId) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        let bytes = endpointID.toBytes()
        var hex: [UInt8] = []
        hex.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    /// Exact-origin allowlist match, tolerating one trailing slash the same
    /// way `CmxIrohLibEndpoint.endpointAddresses` treats hint relay URLs.
    static func isAllowedRelayURL(
        _ url: String,
        allowedRelayURLs: Set<String>
    ) -> Bool {
        if allowedRelayURLs.contains(url) { return true }
        if url.hasSuffix("/") {
            return allowedRelayURLs.contains(String(url.dropLast()))
        }
        return allowedRelayURLs.contains(url + "/")
    }
}
