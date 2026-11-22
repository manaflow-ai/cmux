public import Foundation

/// What a password store did with one batch. Counts only, never values.
public struct PasswordStoreReply: Sendable, Equatable, Codable {
    public var added = 0
    /// Already saved with the same password.
    public var duplicate = 0
    /// Already saved for that site and username with another password; the saved one is kept.
    public var conflict = 0
    /// The store refused the entry.
    public var rejected = 0

    public init(added: Int = 0, duplicate: Int = 0, conflict: Int = 0, rejected: Int = 0) {
        self.added = added
        self.duplicate = duplicate
        self.conflict = conflict
        self.rejected = rejected
    }
}

/// cmux's password store for one browser profile: Chromium's own store in
/// that profile, encrypted with cmux's "cmux Safe Storage" key, which is
/// where autofill reads. The App supplies it (the CEF shim).
public protocol PasswordDestination: Sendable {
    /// Whether this build can write passwords (the fork has the export).
    var isAvailable: Bool { get }
    /// Adds `logins` to cmux browser profile `profileID`, skipping ones it already has.
    func add(_ logins: [ImportedLogin], toProfile profileID: String) async throws -> PasswordStoreReply
}
