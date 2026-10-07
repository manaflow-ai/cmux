/// Why a Noise handshake or transport message failed.
public enum NoiseError: Error, Sendable, Hashable {
    /// Authentication failed: wrong key, tampered or replayed message.
    case decryptionFailed
    /// A handshake message has the wrong length or shape.
    case malformedMessage
    /// A message exceeds Noise's 65535-byte limit.
    case messageTooLarge
    /// The 64-bit nonce is exhausted; the session must re-handshake.
    case nonceExhausted
    /// A key agreement produced an invalid shared secret (low-order point).
    case invalidKey
}
