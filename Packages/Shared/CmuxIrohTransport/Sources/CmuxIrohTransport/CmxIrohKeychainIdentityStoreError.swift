/// Keychain failures surfaced without exposing identity material.
public struct CmxIrohKeychainIdentityStoreError: Error, Equatable, Sendable {
    /// The Security framework status code.
    public let status: Int32

    /// Creates a status-only Keychain error.
    public init(status: Int32) {
        self.status = status
    }
}
