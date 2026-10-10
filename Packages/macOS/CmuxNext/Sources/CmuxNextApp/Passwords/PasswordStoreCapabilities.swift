import Foundation

/// What the running build's store can do. A false section shows "Available after the next
/// update" on the page and refuses its ops with `cmux.passwords.unavailable`.
nonisolated struct PasswordStoreCapabilities: Sendable, Hashable {
    /// List, edit username, delete, reveal and copy saved passwords.
    var passwords: Bool
    var passkeys: Bool
    var exceptions: Bool
    var export: Bool

    static let unsupported = PasswordStoreCapabilities(passwords: false, passkeys: false, exceptions: false, export: false)
}
