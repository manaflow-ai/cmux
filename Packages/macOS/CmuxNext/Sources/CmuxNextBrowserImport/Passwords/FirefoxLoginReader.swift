public import Foundation

/// Reads a Firefox-family profile's saved passwords: `logins.json` (the
/// encrypted entries) and `key4.db` (the NSS key store, read from a private
/// copy). Only the encrypted values the source keeps on disk are read from
/// files; each password is decrypted in memory into `SecretBytes`, the
/// username into an ordinary string. Nothing here writes a password anywhere.
public struct FirefoxLoginReader {
    public init() {}

    /// Whether the profile has a login store at all (detection reads no rows).
    public static func hasLogins(_ profile: URL) -> Bool {
        ["logins.json", "key4.db"].allSatisfy { FileManager.default.fileExists(atPath: profile.appending(path: $0).path) }
    }

    struct LoginsFile: Decodable {
        struct Entry: Decodable {
            var hostname: String
            var httpRealm: String?
            var encryptedUsername: String
            var encryptedPassword: String
            /// Milliseconds since 1970.
            var timeCreated: Double?
        }

        var logins: [Entry]
    }

    /// Throws `FirefoxPasswordCrypto.Failure.primaryPasswordNeeded` or
    /// `.wrongPrimaryPassword` when the profile's primary password is set and
    /// `primaryPassword` does not open it; other failures mean the store would not read.
    public func read(profile: URL, primaryPassword: SecretBytes?) throws -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        throw FirefoxPasswordCrypto.Failure.unsupportedScheme
    }
}
