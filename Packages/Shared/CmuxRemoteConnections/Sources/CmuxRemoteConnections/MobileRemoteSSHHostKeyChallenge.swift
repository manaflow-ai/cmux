public import Foundation

/// A bounded server-key observation from one unauthenticated SSH handshake.
public struct MobileRemoteSSHHostKeyChallenge: Equatable, Sendable {
    /// Profile whose destination produced the key.
    public let profileID: UUID
    /// Negotiated host-key algorithm, at most 128 UTF-8 bytes.
    public let algorithm: String
    /// Fingerprint derived from the actual handshake key, at most 256 UTF-8 bytes.
    public let fingerprint: String

    /// Checks display bounds; this value alone grants no trust.
    /// - Parameters:
    ///   - profileID: Destination profile identity.
    ///   - algorithm: Algorithm reported by the engine for the handshake.
    ///   - fingerprint: Fingerprint computed by the engine from the public key.
    /// - Throws: Invalid-challenge for blank, oversized, or control-character data.
    public init(profileID: UUID, algorithm: String, fingerprint: String) throws {
        guard !algorithm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              algorithm.utf8.count <= 128, fingerprint.utf8.count <= 256,
              !algorithm.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !fingerprint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MobileRemoteSSHError.invalidHostKeyChallenge
        }
        self.profileID = profileID
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }
}
