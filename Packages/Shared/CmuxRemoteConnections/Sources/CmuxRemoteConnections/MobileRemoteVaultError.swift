/// Failures from the local record cipher, with no secret payload in diagnostics.
public enum MobileRemoteVaultError: Error, Equatable, Sendable {
    /// Envelope size, nonce, or authentication tag is invalid.
    case malformedEnvelope
    /// Ciphertext, key, or expected context did not authenticate.
    case authenticationFailed
    /// The envelope uses a version this reader does not implement.
    case unsupportedVersion(Int)
    /// The caller supplied an empty owner or nonpositive version.
    case invalidContext
    /// This format requires a 256-bit encryption key.
    case invalidKeySize
    /// Credential or profile data exceeds the bounded record limit.
    case payloadTooLarge
    /// Deletion records must not contain a hidden live payload.
    case invalidDeletionPayload
    /// A signed sync revision is missing required bounded fields.
    case invalidRevision
    /// A signed sync revision could not be verified by the trusted device key.
    case invalidSignature
}
