import Foundation

// `cloud-conversations-v1` commands (plans/cmux-next/home-cloud-proxy.md
// section 4). The daemon only transports: ConversationDO owns each cloud
// conversation and UserDO owns the inbox. Trusted local connections only.

/// `cloud-session-set`: leases the signed-in account's access token to the
/// daemon (`auth` absent: a bearer token), or names a self-hosted chat
/// server the daemon reaches over Tailscale with no token (`auth:
/// "tailscale"`, `cloud-selfhost-v1`). The daemon keeps a token in memory
/// only and never returns it.
public struct CloudSessionSetRequest: DaemonRequest, CustomStringConvertible {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-set"
    /// An https origin, or http with a loopback host; no path. A self-hosted
    /// server: http or https on a `*.ts.net` name or a tailnet address.
    public var apiBaseURL: String
    /// `tailscale` for a self-hosted server; nil for a bearer token.
    public var auth: String?
    /// The bearer token; nil for a self-hosted server.
    public var accessToken: String?
    /// Unix milliseconds; nil for a self-hosted server (its lease never expires).
    public var expiresAt: UInt64?
    /// Forwarded as `x-cmux-client-version`.
    public var clientVersion: String?

    public init(apiBaseURL: String, accessToken: String, expiresAt: UInt64, clientVersion: String? = nil) {
        self.apiBaseURL = apiBaseURL
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.clientVersion = clientVersion
    }

    /// A self-hosted chat server at `apiBaseURL`: no token; the server knows
    /// the person by their Tailscale login.
    public static func tailscale(apiBaseURL: String, clientVersion: String? = nil) -> Self {
        var request = Self(apiBaseURL: apiBaseURL, accessToken: "", expiresAt: 0, clientVersion: clientVersion)
        request.auth = "tailscale"
        request.accessToken = nil
        request.expiresAt = nil
        return request
    }

    /// Never prints the token.
    public var description: String {
        if let auth { return "cloud-session-set(\(apiBaseURL), auth: \(auth))" }
        return "cloud-session-set(\(apiBaseURL), expires_at: \(expiresAt ?? 0))"
    }
}

/// `cloud-session-clear`: ends the lease (sign-out, account switch).
public struct CloudSessionClearRequest: DaemonRequest {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-clear"
    public init() {}
}

/// `cloud-session-status`.
public struct CloudSessionStatusRequest: DaemonRequest {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-status"
    public init() {}
}

/// `cloud-selfhost-info` (`cloud-selfhost-v1`): who the self-hosted server
/// the lease names says the person is (`GET /v1/selfhost/info`, asked by the
/// daemon without a token). Refused (`not_selfhost`) under a bearer lease.
public struct CloudSelfHostInfoRequest: DaemonRequest {
    public typealias Response = CloudSelfHostInfo
    public static let command = "cloud-selfhost-info"
    public static let requiredCapability: String? = DaemonCapability.cloudSelfHost.rawValue
    public init() {}
}
