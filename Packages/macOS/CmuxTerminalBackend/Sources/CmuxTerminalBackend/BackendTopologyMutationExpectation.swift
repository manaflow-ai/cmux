public import Foundation

/// Server-issued authority for canonical topology mutations on one live connection.
public struct BackendTopologyMutationLease: Equatable, Sendable {
    public let connectionID: UUID
    public let leaseID: UUID
    public let generation: UInt64

    public init?(connectionID: UUID, leaseID: UUID, generation: UInt64) {
        guard connectionID != Self.nilUUID,
              leaseID != Self.nilUUID,
              generation > 0
        else { return nil }
        self.connectionID = connectionID
        self.leaseID = leaseID
        self.generation = generation
    }

    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Exact authority and snapshot revision accepted by one idempotent topology mutation.
public struct BackendTopologyMutationExpectation: Equatable, Sendable {
    /// Caller-generated key retained by the daemon for replay-safe retries.
    public let requestID: UUID

    /// Daemon and logical session allowed to execute the request.
    public let authority: BackendAuthority

    /// Canonical revision against which every stable target is resolved atomically.
    public let revision: UInt64

    /// Server-issued lease for the exact transport connection carrying this mutation.
    public let topologyLease: BackendTopologyMutationLease

    /// Creates one authority-fenced mutation expectation.
    public init(
        requestID: UUID,
        authority: BackendAuthority,
        revision: UInt64,
        topologyLease: BackendTopologyMutationLease
    ) {
        self.requestID = requestID
        self.authority = authority
        self.revision = revision
        self.topologyLease = topologyLease
    }

    internal var jsonParameters: [String: BackendJSONValue] {
        [
            "request_id": .string(requestID.uuidString.lowercased()),
            "daemon_instance_id": .string(authority.daemonInstanceID.description),
            "session_id": .string(authority.sessionID.description),
            "expected_revision": .unsignedInteger(revision),
            "topology_lease_id": .string(topologyLease.leaseID.uuidString.lowercased()),
            "topology_lease_generation": .unsignedInteger(topologyLease.generation),
        ]
    }
}
