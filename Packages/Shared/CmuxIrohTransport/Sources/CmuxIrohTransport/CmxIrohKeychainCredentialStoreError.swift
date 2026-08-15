/// A Keychain failure that never contains credential material.
public struct CmxIrohKeychainCredentialStoreError: Error, Equatable, Sendable {
    /// The Security framework status code.
    public let status: Int32

    /// Creates a status-only Keychain error.
    ///
    /// - Parameter status: The Security framework status code.
    public init(status: Int32) {
        self.status = status
    }
}
