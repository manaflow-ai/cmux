public import Foundation

/// Plaintext credential material that must only exist while being consumed by
/// a carrier. It is deliberately separate from profile metadata and vault
/// envelopes. Swift value copies are not guaranteed to be securely erased;
/// limit lifetime and do not retain these values in UI or sync state.
public enum MobileRemoteCredentialMaterial: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Password bytes represented as text for the SSH authentication API.
    case password(String)
    /// Software key bytes and optional unlocking passphrase.
    case privateKey(Data, passphrase: String?)
    /// Redacted human-readable representation.
    public var description: String { "<remote credential redacted>" }
    /// Redacted debugger representation.
    public var debugDescription: String { description }
    /// Prevents generic mirror-based logging from walking secret payloads.
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
