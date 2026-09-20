public import Foundation

/// Untrusted host-key observation suitable for diagnostics or import.
///
/// This value cannot grant trust; accepted keys require a separate trust store.
public struct MobileRemoteHostKeyObservation: Codable, Equatable, Identifiable, Sendable {
    /// Observation identifier.
    public let id: UUID
    /// Profile whose host produced this key.
    public let profileID: UUID
    /// Server-reported SSH host-key algorithm.
    public let algorithm: String
    /// Fingerprint of the observed public key; not an acceptance decision.
    public let fingerprint: String
    /// Time this key was first observed.
    public let firstSeenAt: Date
    /// Most recent observation time.
    public let lastSeenAt: Date

    /// Creates an observation without granting trust.
    ///
    /// - Parameters:
    ///   - id: Observation identifier.
    ///   - profileID: Source profile identifier.
    ///   - algorithm: Host key algorithm.
    ///   - fingerprint: Public-key fingerprint.
    ///   - firstSeenAt: First observation time.
    ///   - lastSeenAt: Last observation time.
    public init(
        id: UUID,
        profileID: UUID,
        algorithm: String,
        fingerprint: String,
        firstSeenAt: Date,
        lastSeenAt: Date
    ) {
        self.id = id
        self.profileID = profileID
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}
