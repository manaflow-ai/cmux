import Foundation

/// Five-minute QR authorization created by the Mac for one offline pairing attempt.
public struct CmxIrohOfflinePairingInvitation: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let proof: String
    public let expiresAt: Int64
    public let acceptorAttestation: String

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID = "session_id"
        case proof
        case expiresAt = "expires_at"
        case acceptorAttestation = "acceptor_attestation"
    }

    init(
        sessionID: String,
        proof: String,
        expiresAt: Int64,
        acceptorAttestation: String
    ) {
        version = 1
        self.sessionID = sessionID
        self.proof = proof
        self.expiresAt = expiresAt
        self.acceptorAttestation = acceptorAttestation
    }

    /// Creates the control-stream credential presented by the iOS initiator.
    public func admissionCredential(
        initiatorAttestation: String
    ) throws -> CmxIrohAdmissionCredential {
        guard version == 1,
              let proofBytes = Self.decodeBase64URL(proof),
              proofBytes.count == 32 else {
            throw CmxIrohOfflinePairingSessionError.invalidInvitation
        }
        return try CmxIrohAdmissionCredential.offlinePairing(
            endpointAttestation: initiatorAttestation,
            invitationID: CmxIrohResourceID(sessionID),
            proof: proofBytes
        )
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
                      || byte == 45 || byte == 95
              }) else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let decoded = Data(base64Encoded: standard),
              decoded.base64URL == value else {
            return nil
        }
        return decoded
    }
}

extension Data {
    fileprivate var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
