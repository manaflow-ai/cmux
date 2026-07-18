public import Foundation

/// Exact authority and snapshot revision accepted by one idempotent topology mutation.
public struct BackendTopologyMutationExpectation: Equatable, Sendable {
    /// Caller-generated key retained by the daemon for replay-safe retries.
    public let requestID: UUID

    /// Daemon and logical session allowed to execute the request.
    public let authority: BackendAuthority

    /// Canonical revision against which every stable target is resolved atomically.
    public let revision: UInt64

    /// Creates one authority-fenced mutation expectation.
    public init(requestID: UUID, authority: BackendAuthority, revision: UInt64) {
        self.requestID = requestID
        self.authority = authority
        self.revision = revision
    }

    internal var jsonParameters: [String: BackendJSONValue] {
        [
            "request_id": .string(requestID.uuidString.lowercased()),
            "daemon_instance_id": .string(authority.daemonInstanceID.description),
            "session_id": .string(authority.sessionID.description),
            "expected_revision": .unsignedInteger(revision),
        ]
    }
}
