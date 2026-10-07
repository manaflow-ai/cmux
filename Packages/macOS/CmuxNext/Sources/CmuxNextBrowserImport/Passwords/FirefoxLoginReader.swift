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
        let key4 = try SQLiteSnapshot(copying: profile.appending(path: "key4.db"))
        guard key4.hasTable("metaData"), key4.hasTable("nssPrivate") else { throw FirefoxPasswordCrypto.Failure.malformed }
        let crypto = try FirefoxPasswordCrypto(key4: key4, primaryPassword: primaryPassword)
        let file = try JSONDecoder().decode(LoginsFile.self, from: Data(contentsOf: profile.appending(path: "logins.json")))

        var skipped = LoginSkipCounts()
        var byKey: [String: ImportedLogin] = [:]
        var order: [String] = []
        for (index, entry) in file.logins.enumerated() {
            if index % 256 == 255 { try Task.checkCancellation() }
            // HTTP authentication rows carry a realm; extension and about: origins are not web forms.
            guard entry.httpRealm == nil, let (url, realm) = PasswordCSVReader.webForm(entry.hostname) else {
                skipped.notWebForm += 1
                continue
            }
            let password: SecretBytes
            let username: String
            do {
                password = try crypto.decrypt(entry.encryptedPassword)
                username = try crypto.decrypt(entry.encryptedUsername).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            } catch {
                skipped.undecryptable += 1
                continue
            }
            guard password.withUnsafeBytes(ChromiumPasswordCrypto.isUTF8) else {
                skipped.undecryptable += 1
                continue
            }
            guard !password.isEmpty else {
                skipped.empty += 1
                continue
            }
            let created = entry.timeCreated.map { Date(timeIntervalSince1970: $0 / 1000) }
            let login = ImportedLogin(url: url, signonRealm: realm, username: username, password: password, created: created)
            let key = realm + "\u{0}" + username
            if let kept = byKey[key] {
                skipped.duplicate += 1
                if (created ?? .distantPast) > (kept.created ?? .distantPast) { byKey[key] = login }
            } else {
                byKey[key] = login
                order.append(key)
            }
        }
        return (order.compactMap { byKey[$0] }, skipped)
    }
}
