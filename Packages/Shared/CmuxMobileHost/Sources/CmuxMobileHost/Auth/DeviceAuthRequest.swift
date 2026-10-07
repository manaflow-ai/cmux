import CmuxMobileWire
import Foundation

/// What a hello presents for admission.
public struct DeviceAuthRequest: Sendable {
    public var client: HelloClient
    public var proof: DeviceProof?
    /// The link session the hello arrived on (bound into the proof).
    public var sessionID: UUID
    public var attestation: CarrierAttestation?

    public init(client: HelloClient, proof: DeviceProof?, sessionID: UUID, attestation: CarrierAttestation? = nil) {
        self.client = client
        self.proof = proof
        self.sessionID = sessionID
        self.attestation = attestation
    }
}
