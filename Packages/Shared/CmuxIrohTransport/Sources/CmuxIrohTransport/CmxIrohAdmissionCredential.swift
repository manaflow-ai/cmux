public import Foundation

/// A bounded admission proof sent only on the first control stream.
public struct CmxIrohAdmissionCredential: Equatable, Sendable {
    /// The credential's validation path.
    public let kind: CmxIrohAdmissionCredentialKind

    /// The backend-signed pair grant for ``CmxIrohAdmissionCredentialKind/pairGrant``.
    public let pairGrantToken: String?

    /// The caller's backend-signed endpoint attestation for offline pairing.
    public let endpointAttestation: String?

    /// The one-use invitation selected by a local pairing QR.
    public let invitationID: CmxIrohResourceID?

    /// The 32-byte proof derived from the invitation secret and both EndpointIDs.
    public let offlineProof: Data?

    private init(
        kind: CmxIrohAdmissionCredentialKind,
        pairGrantToken: String?,
        endpointAttestation: String?,
        invitationID: CmxIrohResourceID?,
        offlineProof: Data?
    ) {
        self.kind = kind
        self.pairGrantToken = pairGrantToken
        self.endpointAttestation = endpointAttestation
        self.invitationID = invitationID
        self.offlineProof = offlineProof
    }

    /// Creates a credential from a backend-signed pair grant.
    ///
    /// - Parameter token: A compact EdDSA JWS no larger than 12 KiB.
    /// - Returns: A validated pair-grant credential.
    /// - Throws: ``CmxIrohAdmissionCredentialError/invalidSignedToken`` for malformed input.
    public static func pairGrant(_ token: String) throws -> CmxIrohAdmissionCredential {
        guard Self.isValidCompactJWS(token) else {
            throw CmxIrohAdmissionCredentialError.invalidSignedToken
        }
        return CmxIrohAdmissionCredential(
            kind: .pairGrant,
            pairGrantToken: token,
            endpointAttestation: nil,
            invitationID: nil,
            offlineProof: nil
        )
    }

    /// Creates a first-pair credential that preserves same-account authorization offline.
    ///
    /// QR possession supplies the one-use invitation. The endpoint attestation
    /// independently proves the caller's cached Stack account binding.
    ///
    /// - Parameters:
    ///   - endpointAttestation: A compact backend-signed endpoint-attestation JWS.
    ///   - invitationID: The opaque one-use invitation identifier from the QR.
    ///   - proof: A 32-byte proof bound to both EndpointIDs.
    /// - Returns: A validated offline-pairing credential.
    /// - Throws: ``CmxIrohAdmissionCredentialError`` when a field is malformed.
    public static func offlinePairing(
        endpointAttestation: String,
        invitationID: CmxIrohResourceID,
        proof: Data
    ) throws -> CmxIrohAdmissionCredential {
        guard Self.isValidCompactJWS(endpointAttestation) else {
            throw CmxIrohAdmissionCredentialError.invalidSignedToken
        }
        guard proof.count == 32 else {
            throw CmxIrohAdmissionCredentialError.invalidOfflineProofLength(proof.count)
        }
        return CmxIrohAdmissionCredential(
            kind: .offlinePairing,
            pairGrantToken: nil,
            endpointAttestation: endpointAttestation,
            invitationID: invitationID,
            offlineProof: proof
        )
    }

    private static func isValidCompactJWS(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (5 ... 12 * 1_024).contains(bytes.count) else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else { return false }
        return segments.joined().utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}
