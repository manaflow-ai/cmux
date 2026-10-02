public import Foundation

/// One saved sign-in read from a source browser. The password is
/// `SecretBytes`; the rest is what the source shows in its password list.
/// Descriptions are redacted so a stray print or log line carries nothing.
public struct ImportedLogin: Sendable, CustomStringConvertible, CustomReflectable {
    /// The page the form was on (`origin_url`).
    public var url: String
    /// Chromium's match key (`signon_realm`), for example "https://github.com/".
    public var signonRealm: String
    public var username: String
    public var password: SecretBytes
    public var created: Date?

    public init(url: String, signonRealm: String, username: String, password: SecretBytes, created: Date?) {
        self.url = url
        self.signonRealm = signonRealm
        self.username = username
        self.password = password
        self.created = created
    }

    public var description: String { "ImportedLogin(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// What a read left out, by reason. Counts only.
public struct LoginSkipCounts: Sendable, Equatable, Codable {
    /// "Never save" entries: a site, no password.
    public var neverSaved = 0
    /// Sign in with another provider (federated), Android app and HTTP auth entries.
    public var notWebForm = 0
    /// No password (username-only entries).
    public var empty = 0
    /// The key did not open the value.
    public var undecryptable = 0
    /// The same site and username twice in this source (the newest is kept).
    public var duplicate = 0

    public init() {}

    public var total: Int { neverSaved + notWebForm + empty + undecryptable + duplicate }
}

/// Reads a Chromium profile's saved passwords: `Login Data` (the profile
/// store) and `Login Data For Account` (the account store). Each database is
/// read from a private copy (`SQLiteSnapshot`), which holds only the
/// encrypted values the source keeps on disk anyway; each value is decrypted
/// in memory into `SecretBytes`. Nothing here writes a password anywhere.
public struct ChromiumLoginDataReader {
    public init() {}

    public static let files = ["Login Data", "Login Data For Account"]

    /// Whether the profile has a login database at all (detection reads no rows).
    public static func hasLogins(_ profile: URL) -> Bool {
        files.contains { FileManager.default.fileExists(atPath: profile.appending(path: $0).path) }
    }

    public func read(profile: URL, crypto: ChromiumPasswordCrypto) throws -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        var skipped = LoginSkipCounts()
        var byKey: [String: ImportedLogin] = [:]
        var order: [String] = []
        for name in Self.files {
            let file = profile.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let database = try SQLiteSnapshot(copying: file)
            guard database.hasTable("logins") else { continue }
            let sql = "SELECT origin_url, signon_realm, username_value, password_value, date_created, blacklisted_by_user, scheme, "
                + "federation_url FROM logins"
            try database.query(sql) { row in
                let realm = row.string(1) ?? ""
                // scheme 0 is an HTML form; 1-3 are HTTP auth. Federated and Android entries have no web password.
                guard row.int64(5) == 0 else { skipped.neverSaved += 1; return true }
                guard row.int64(6) == 0, (row.string(7) ?? "").isEmpty, realm.hasPrefix("http") else {
                    skipped.notWebForm += 1
                    return true
                }
                guard let sealed = row.data(3), !sealed.isEmpty else { skipped.empty += 1; return true }
                let password: SecretBytes
                do {
                    password = try crypto.decrypt(sealed)
                } catch {
                    skipped.undecryptable += 1
                    return true
                }
                guard !password.isEmpty else { skipped.empty += 1; return true }
                let login = ImportedLogin(url: row.string(0) ?? realm, signonRealm: realm, username: row.string(2) ?? "",
                                          password: password, created: BrowserTime().chromium(row.int64(4)))
                let key = realm + "\u{0}" + login.username
                if let kept = byKey[key] {
                    skipped.duplicate += 1
                    if (login.created ?? .distantPast) > (kept.created ?? .distantPast) { byKey[key] = login }
                } else {
                    byKey[key] = login
                    order.append(key)
                }
                return true
            }
        }
        return (order.compactMap { byKey[$0] }, skipped)
    }
}
