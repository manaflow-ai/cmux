import Foundation

/// A short-lived WebSocket lease minted by the Cloud VM backend.
///
/// A lease carries the WebSocket URL, provider-specific handshake headers, the
/// lease token, the opaque backend session id, and the Unix expiry time. The
/// terminal and daemon leases share this field set even though the backend
/// places the terminal lease at the top level and the daemon lease in a nested
/// object.
public struct CmxCloudAttachLease: Codable, Equatable, Sendable {
    /// The WebSocket URL for the leased endpoint.
    public let url: String
    /// Handshake headers to send when opening the WebSocket.
    ///
    /// E2B uses `e2b-traffic-access-token`; Freestyle authorizes by token alone
    /// and therefore leaves this empty.
    public let headers: [String: String]
    /// The short-lived authorization token for the lease.
    public let token: String
    /// The backend session id sent alongside the token in cmuxd-remote auth.
    public let sessionID: String
    /// The lease expiry as a Unix timestamp in seconds.
    ///
    /// The backend stores `new Date(expiresAtUnix * 1000)`.
    public let expiresAtUnix: Double

    /// The lease expiry as a `Date`.
    ///
    /// The backend field is required. Preserving `0` or negative values as real
    /// dates makes invalid leases appear expired instead of open-ended.
    public var expiresAt: Date {
        return Date(timeIntervalSince1970: expiresAtUnix)
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case headers
        case token
        case sessionID = "sessionId"
        case expiresAtUnix
    }

    /// Creates a Cloud VM WebSocket lease.
    ///
    /// - Parameter url: The WebSocket URL for the leased endpoint.
    /// - Parameter headers: Headers to send during the WebSocket handshake.
    ///   Defaults to an empty dictionary for token-only providers.
    /// - Parameter token: The short-lived authorization token for the lease.
    /// - Parameter sessionID: The backend session id sent during auth.
    /// - Parameter expiresAtUnix: The lease expiry as Unix seconds.
    public init(
        url: String,
        headers: [String: String] = [:],
        token: String,
        sessionID: String,
        expiresAtUnix: Double
    ) {
        self.url = url
        self.headers = headers
        self.token = token
        self.sessionID = sessionID
        self.expiresAtUnix = expiresAtUnix
    }

    /// Decodes a lease from backend JSON.
    ///
    /// - Parameter decoder: The decoder positioned at a lease object or the
    ///   top-level endpoint object for the flattened terminal lease.
    /// - Throws: A `DecodingError` when required lease fields are malformed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        token = try container.decode(String.self, forKey: .token)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        expiresAtUnix = try container.decode(Double.self, forKey: .expiresAtUnix)
    }

    /// Encodes a lease to backend JSON.
    ///
    /// Empty header dictionaries are omitted so token-only providers round-trip
    /// without adding a synthetic `headers: {}` field.
    ///
    /// - Parameter encoder: The encoder that receives the lease object.
    /// - Throws: An encoding error from the supplied encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        if !headers.isEmpty {
            try container.encode(headers, forKey: .headers)
        }
        try container.encode(token, forKey: .token)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(expiresAtUnix, forKey: .expiresAtUnix)
    }
}
