public import Foundation

extension CloudVPNConfigurationKeychain {
    /// Keychain failures. Deliberately carries no item contents.
    public enum Failure: Error, Sendable, Equatable {
        /// The Keychain operation returned this status.
        case storage(OSStatus)
    }
}
