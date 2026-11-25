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
    public static let command = "cloud-host-replica-set"
    /// An https origin, or http with a loopback host; no path.
    public var apiBaseURL: String
    public var installToken: String
    /// Unix milliseconds.
    public var expiresAt: UInt64
    public var clientVersion: String?
    /// The name phones show for this Mac.
    public var hostName: String
    /// Seals every published state (RFD 0163 row 7). Off (nil) unless the
    /// daemon serves ``DaemonCapability/cloudHostReplicaSeal``: an older
    /// daemon ignores the field and would publish in the clear.
    public var seal: CloudHostReplicaSeal?

    public init(apiBaseURL: String, installToken: String, expiresAt: UInt64, clientVersion: String? = nil, hostName: String,
                seal: CloudHostReplicaSeal? = nil) {
        self.apiBaseURL = apiBaseURL
        self.installToken = installToken
        self.expiresAt = expiresAt
        self.clientVersion = clientVersion
        self.hostName = hostName
        self.seal = seal
    }

    /// Never prints the token or the seal's key.
    public var description: String {
        "cloud-host-replica-set(\(apiBaseURL), expires_at: \(expiresAt), sealed: \(seal.map { "\($0.viewers.count) viewers" } ?? "no"))"
    }
}

/// The `seal` of `cloud-host-replica-set` (cmux-next-ios PROTOCOL.md "Host
/// replica sealed state"): the Mac identity key and the key agreement key
/// (`pushKey`) of every device the pairing store pairs now.
public struct CloudHostReplicaSeal: Sendable, Equatable, Encodable, CustomStringConvertible {
    /// The Mac identity key's 32-byte private scalar, base64.
    public var sourceKey: String
    /// The paired devices' P-256 public keys (X9.63), base64; 1 to 16.
    public var viewers: [String]

    public init(sourceKey: String, viewers: [String]) {
        self.sourceKey = sourceKey
        self.viewers = viewers
    }

    /// Never prints the key.
    public var description: String { "CloudHostReplicaSeal(\(viewers.count) viewers)" }
}

/// `cloud-host-replica-clear`: drops the lease. `purge` deletes the cloud
/// copy first; the lease goes when the cloud confirms.
public struct CloudHostReplicaClearRequest: DaemonRequest {
    public typealias Response = CloudHostReplicaState
    public static let command = "cloud-host-replica-clear"
    public var purge: Bool

    public init(purge: Bool) {
        self.purge = purge
    }
}

/// `cloud-host-replica-status`.
public struct CloudHostReplicaStatusRequest: DaemonRequest {
    public typealias Response = CloudHostReplicaState
    public static let command = "cloud-host-replica-status"
    public init() {}
}
