public import Foundation

/// Persistence for ``CloudDeviceIdentity``.
///
/// `read` distinguishes "nothing stored" from "store unreadable right now"
/// so a locked Keychain never causes a re-mint that strands the enrolled
/// tunnel.
public protocol CloudDeviceIdentityStoring: Sendable {
    /// The stored identity, `.absent` on a fresh install, `.unavailable` when
    /// the store cannot be read now.
    func read() -> CloudDeviceIdentityReadResult
    /// Persist `identity`, overwriting any previous value.
    func write(_ identity: CloudDeviceIdentity) throws
}

/// Outcome of ``CloudDeviceIdentityStoring/read()``.
public enum CloudDeviceIdentityReadResult: Sendable, Equatable {
    /// A stored identity.
    case found(CloudDeviceIdentity)
    /// The store is readable and empty.
    case absent
    /// The store cannot be read now (for example the Keychain before first unlock).
    case unavailable
}

/// Failures of an identity store.
public enum CloudDeviceIdentityStoreError: Error, Equatable, Sendable {
    /// The Keychain refused the write with the given `OSStatus`.
    case keychain(Int32)
    /// A stored value could not be decoded.
    case corrupt
}
