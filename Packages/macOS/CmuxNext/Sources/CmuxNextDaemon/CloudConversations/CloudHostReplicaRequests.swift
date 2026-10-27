public import Foundation

// `cloud-host-replica-v1` (plans/cmux-next/object-sync/DESIGN.md phase 3,
// cmux-tui/spec/commands.md): the daemon publishes a narrow copy of this
// Mac's workspace list to the Cloud service with the app's install token.
// The verified app connection only.

/// `cloud-host-replica-set`: leases the install token to the publisher. The
/// daemon keeps it in memory only and never returns it. A lease for the same
/// user, install and origin is a renewal that keeps the open socket.
public struct CloudHostReplicaSetRequest: DaemonRequest, CustomStringConvertible {
    public typealias Response = CloudHostReplicaState
    public static let commandName: DaemonCommandName = "cloud-host-replica-set"
    /// An https origin, or http with a loopback host; no path.
    public var apiBaseURL: String
    public var installToken: String
    /// Unix milliseconds.
    public var expiresAt: UInt64
    public var clientVersion: String?
    /// The name phones show for this Mac.
    public var hostName: String

    public init(apiBaseURL: String, installToken: String, expiresAt: UInt64, clientVersion: String? = nil, hostName: String) {
        self.apiBaseURL = apiBaseURL
        self.installToken = installToken
        self.expiresAt = expiresAt
        self.clientVersion = clientVersion
        self.hostName = hostName
    }

    /// Never prints the token.
    public var description: String { "cloud-host-replica-set(\(apiBaseURL), expires_at: \(expiresAt))" }

    enum CodingKeys: String, CodingKey {
        case apiBaseURL = "api_base_url", installToken = "install_token", expiresAt = "expires_at"
        case clientVersion = "client_version", hostName = "host_name"
    }
}

/// `cloud-host-replica-clear`: drops the lease. `purge` deletes the cloud
/// copy first; the lease goes when the cloud confirms.
public struct CloudHostReplicaClearRequest: DaemonRequest {
    public typealias Response = CloudHostReplicaState
    public static let commandName: DaemonCommandName = "cloud-host-replica-clear"
    public var purge: Bool

    public init(purge: Bool) {
        self.purge = purge
    }
}

/// `cloud-host-replica-status`.
public struct CloudHostReplicaStatusRequest: DaemonRequest {
    public typealias Response = CloudHostReplicaState
    public static let commandName: DaemonCommandName = "cloud-host-replica-status"
    public init() {}
}
