package import Foundation

/// One saved sign-in as the Passwords page sees it: metadata only, never the password
/// (plans/cmux-next/passwords.md 1.4, plaintext rule).
package nonisolated struct SavedPassword: Sendable, Hashable {
    package var id: String
    /// The site the sign-in belongs to (`github.com`).
    package var site: String
    package var url: String
    package var username: String
    package var created: Date?
    package var lastUsed: Date?
    package var timesUsed: Int
    package var weak: Bool
    package var reused: Bool

    package init(id: String, site: String, url: String, username: String, created: Date? = nil, lastUsed: Date? = nil, timesUsed: Int, weak: Bool, reused: Bool) {
        self.id = id
        self.site = site
        self.url = url
        self.username = username
        self.created = created
        self.lastUsed = lastUsed
        self.timesUsed = timesUsed
        self.weak = weak
        self.reused = reused
    }
}

/// One profile (Touch ID) passkey: metadata only.
package nonisolated struct SavedPasskey: Sendable, Hashable {
    /// The credential id (base64url), the delete key.
    package var id: String
    package var relyingParty: String
    package var userName: String
    package var userDisplayName: String

    package init(id: String, relyingParty: String, userName: String, userDisplayName: String) {
        self.id = id
        self.relyingParty = relyingParty
        self.userName = userName
        self.userDisplayName = userDisplayName
    }
}

/// One site the person told cmux never to save a password for.
package nonisolated struct PasswordException: Sendable, Hashable {
    package var id: String
    package var site: String

    package init(id: String, site: String) {
        self.id = id
        self.site = site
    }
}
