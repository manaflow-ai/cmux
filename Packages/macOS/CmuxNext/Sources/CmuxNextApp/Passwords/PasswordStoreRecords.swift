import Foundation

/// One saved sign-in as the Passwords page sees it: metadata only, never the password
/// (plans/cmux-next/passwords.md 1.4, plaintext rule).
nonisolated struct SavedPassword: Sendable, Hashable {
    var id: String
    /// The site the sign-in belongs to (`github.com`).
    var site: String
    var url: String
    var username: String
    var created: Date?
    var lastUsed: Date?
    var timesUsed: Int
    var weak: Bool
    var reused: Bool
}

/// One profile (Touch ID) passkey: metadata only.
nonisolated struct SavedPasskey: Sendable, Hashable {
    /// The credential id (base64url), the delete key.
    var id: String
    var relyingParty: String
    var userName: String
    var userDisplayName: String
}

/// One site the person told cmux never to save a password for.
nonisolated struct PasswordException: Sendable, Hashable {
    var id: String
    var site: String
}
