public import CryptoKit
public import Foundation

/// Encrypts individual vault records with account- and revision-bound AEAD.
///
/// This primitive does not implement vault membership, key distribution,
/// recovery, trusted revision tracking, or device revocation.
public struct MobileRemoteVaultCipher: Sendable {
    /// Creates a stateless record cipher.
    public init() {}

    /// Seals a record with a fresh random nonce.
    ///
    /// - Parameters:
    ///   - plaintext: Bounded record data, empty for a deletion.
    ///   - context: Expected owner, record identity, and revision.
    ///   - key: A 256-bit key for the context's vault epoch.
    /// - Returns: Ciphertext safe to give to the sync transport.
    /// - Throws: Validation or CryptoKit encryption errors.
    public func encrypt(
        _ plaintext: Data,
        context: MobileRemoteVaultContext,
        key: SymmetricKey
    ) throws -> MobileRemoteVaultEnvelope {
        guard key.bitCount == 256 else { throw MobileRemoteVaultError.invalidKeySize }
        guard plaintext.count <= MobileRemoteVaultEnvelope.maximumPayloadBytes else {
            throw MobileRemoteVaultError.payloadTooLarge
        }
        guard !context.deleted || plaintext.isEmpty else {
            throw MobileRemoteVaultError.invalidDeletionPayload
        }
        let sealed = try AES.GCM.seal(
            plaintext, using: key,
            authenticating: context.associatedData(version: MobileRemoteVaultEnvelope.currentVersion)
        )
        guard let combined = sealed.combined else {
            throw MobileRemoteVaultError.malformedEnvelope
        }
        return try MobileRemoteVaultEnvelope(sealedBox: combined)
    }

    /// Authenticates a record against independently known context.
    ///
    /// - Parameters:
    ///   - envelope: Bounded received ciphertext.
    ///   - context: Context expected by the caller, not learned from this blob.
    ///   - key: A 256-bit key for the expected vault epoch.
    /// - Returns: Plaintext only after authentication succeeds.
    /// - Throws: Key-size or authentication errors, never plaintext.
    public func decrypt(
        _ envelope: MobileRemoteVaultEnvelope,
        context: MobileRemoteVaultContext,
        key: SymmetricKey
    ) throws -> Data {
        guard key.bitCount == 256 else { throw MobileRemoteVaultError.invalidKeySize }
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: envelope.sealedBox)
            plaintext = try AES.GCM.open(
                sealed, using: key,
                authenticating: context.associatedData(version: envelope.version)
            )
        } catch {
            throw MobileRemoteVaultError.authenticationFailed
        }
        guard !context.deleted || plaintext.isEmpty else {
            throw MobileRemoteVaultError.invalidDeletionPayload
        }
        return plaintext
    }
}
