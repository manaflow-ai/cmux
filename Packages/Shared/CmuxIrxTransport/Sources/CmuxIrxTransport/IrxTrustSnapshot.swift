public import Foundation
public import CmuxIrohTransport

/// Persisted grant-verification material and relay fleet from discovery.
public struct IrxTrustSnapshot: Codable, Equatable, Sendable {
    public var verificationKeys: CmxIrohGrantVerificationKeySet
    public var relayFleet: [String]
    public var fetchedAt: Date

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
