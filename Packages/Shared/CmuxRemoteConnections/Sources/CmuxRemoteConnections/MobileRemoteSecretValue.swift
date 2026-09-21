public import Foundation

/// Opaque plaintext bytes held briefly while a carrier consumes a secret.
///
/// This type intentionally does not conform to ``Codable`` and redacts its
/// textual and reflection representations. Swift value copies are not
/// guaranteed to be zeroized, so callers should keep values short-lived.
public struct MobileRemoteSecretValue: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let storage: Data

    /// Creates a secret from bytes without serializing or logging them.
    ///
    /// - Parameter bytes: The plaintext bytes to protect in the local Keychain.
    public init(bytes: Data) {
        self.storage = bytes
    }

    /// Creates a secret from UTF-8 text without retaining a user-facing label.
    ///
    /// - Parameter text: Text consumed by a password or passphrase authenticator.
    public init(text: String) {
        self.storage = Data(text.utf8)
    }

    /// Returns plaintext bytes to the immediate caller.
    public var bytes: Data { storage }

    /// Redacted textual representation.
    public var description: String { "<remote secret redacted>" }

    /// Redacted debugger representation.
    public var debugDescription: String { description }

    /// Prevents mirror-based diagnostics from traversing secret bytes.
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
