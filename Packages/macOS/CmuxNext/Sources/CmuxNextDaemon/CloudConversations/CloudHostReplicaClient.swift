public import Foundation

// `cloud-host-replica-v1` replies, the ask event and the client (split from
// CloudHostReplicaRequests.swift, which holds the requests).

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
        await connection.identity?.supports(DaemonCapability.cloudHostReplica.rawValue) == true
    }

    private func send<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapability.cloudHostReplica.rawValue])
        }
        return try await connection.request(request)
    }

    public func set(_ request: CloudHostReplicaSetRequest) async throws -> CloudHostReplicaState { try await send(request) }
    public func clear(purge: Bool) async throws -> CloudHostReplicaState { try await send(CloudHostReplicaClearRequest(purge: purge)) }
    public func status() async throws -> CloudHostReplicaState { try await send(CloudHostReplicaStatusRequest()) }
}
