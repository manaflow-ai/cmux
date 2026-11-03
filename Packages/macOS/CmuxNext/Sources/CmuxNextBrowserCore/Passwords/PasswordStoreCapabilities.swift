package import Foundation

/// What the running build's store can do. A false section shows "Available after the next
/// update" on the page and refuses its ops with `cmux.passwords.unavailable`.
package nonisolated struct PasswordStoreCapabilities: Sendable, Hashable {
    /// List, edit username, delete, reveal and copy saved passwords.
    package var passwords: Bool
    package var passkeys: Bool
    package var exceptions: Bool
    package var export: Bool

    package static let unsupported = PasswordStoreCapabilities(passwords: false, passkeys: false, exceptions: false, export: false)

    package init(passwords: Bool, passkeys: Bool, exceptions: Bool, export: Bool) {
        self.passwords = passwords
        self.passkeys = passkeys
        self.exceptions = exceptions
        self.export = export
    }
}
