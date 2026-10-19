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

    public init(apiBaseURL: String, installToken: String, expiresAt: UInt64, clientVersion: String? = nil, hostName: String) {
        self.apiBaseURL = apiBaseURL
        self.installToken = installToken
        self.expiresAt = expiresAt
        self.clientVersion = clientVersion
        self.hostName = hostName
    }

    /// Never prints the token.
    public var description: String { "cloud-host-replica-set(\(apiBaseURL), expires_at: \(expiresAt))" }
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

/// The publisher's state. Never carries the token.
public struct CloudHostReplicaState: Decodable, Sendable, Equatable {
    /// `off`, `connecting`, `online`, `unauthenticated`, `forbidden`,
    /// `purging`, `backoff` or `replaced`.
    public var state: String
    public var host: String?
    public var expiresAt: UInt64?
    public var purgePending: Bool?
    public var purgeUnconfirmed: Bool?
    public var lastError: String?

    public init(state: String, host: String? = nil, expiresAt: UInt64? = nil, purgePending: Bool? = nil,
                purgeUnconfirmed: Bool? = nil, lastError: String? = nil) {
        self.state = state
        self.host = host
        self.expiresAt = expiresAt
        self.purgePending = purgePending
        self.purgeUnconfirmed = purgeUnconfirmed
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case state, host
        case expiresAt = "expires_at"
        case purgePending = "purge_pending"
        case purgeUnconfirmed = "purge_unconfirmed"
        case lastError = "last_error"
    }
}

/// `cloud-host-replica-needed`: the publisher asks for a new install token.
public struct CloudHostReplicaNeeded: Decodable, Sendable, Hashable {
    /// `expiring` (within two minutes of `expiresAt`) or `unauthenticated`
    /// (the cloud refused the token).
    public var reason: String
    public var expiresAt: UInt64?

    public init(reason: String, expiresAt: UInt64? = nil) {
        self.reason = reason
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case expiresAt = "expires_at"
    }
}

/// The `cloud-host-replica-*` commands over the verified app's daemon
/// connection; each throws `missingCapabilities` on a daemon without them.
public struct CloudHostReplicaClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    public static func supported(by connection: DaemonConnection) async -> Bool {
        await connection.identity?.supports(DaemonCapabilities.shared.cloudHostReplica) == true
    }

    private func send<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.cloudHostReplica])
        }
        return try await connection.request(request)
    }

    public func set(_ request: CloudHostReplicaSetRequest) async throws -> CloudHostReplicaState { try await send(request) }
    public func clear(purge: Bool) async throws -> CloudHostReplicaState { try await send(CloudHostReplicaClearRequest(purge: purge)) }
    public func status() async throws -> CloudHostReplicaState { try await send(CloudHostReplicaStatusRequest()) }
}
