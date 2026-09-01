public import Foundation
public import CmuxIrohTransport

/// Persisted grant-verification material and relay fleet from discovery.
public struct IrxTrustSnapshot: Codable, Equatable, Sendable {
    /// Broker verification keys used to validate pair grants.
    public var verificationKeys: CmxIrohGrantVerificationKeySet
    /// Trusted relay origins advertised by the broker.
    public var relayFleet: [String]
    /// Time at which this discovery snapshot was fetched.
    public var fetchedAt: Date

    /// Creates a persisted discovery/trust snapshot.
    public init(
        verificationKeys: CmxIrohGrantVerificationKeySet,
        relayFleet: [String],
        fetchedAt: Date
    ) {
        self.verificationKeys = verificationKeys
        self.relayFleet = relayFleet
        self.fetchedAt = fetchedAt
    }
}
