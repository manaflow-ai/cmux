import Foundation

// `cloud-conversations-v1` commands (plans/cmux-next/home-cloud-proxy.md
// section 4). The daemon only transports: ConversationDO owns each cloud
// conversation and UserDO owns the inbox. Trusted local connections only.

/// `cloud-session-set`: leases the signed-in account's access token to the
/// daemon. The daemon keeps it in memory only and never returns it.
public struct CloudSessionSetRequest: DaemonRequest, CustomStringConvertible {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-set"
    /// An https origin, or http with a loopback host; no path.
    public var apiBaseURL: String
    public var accessToken: String
    /// Unix milliseconds.
    public var expiresAt: UInt64
    /// Forwarded as `x-cmux-client-version`.
    public var clientVersion: String?

    public init(apiBaseURL: String, accessToken: String, expiresAt: UInt64, clientVersion: String? = nil) {
        self.apiBaseURL = apiBaseURL
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.clientVersion = clientVersion
    }

    /// Never prints the token.
    public var description: String { "cloud-session-set(\(apiBaseURL), expires_at: \(expiresAt))" }
}
