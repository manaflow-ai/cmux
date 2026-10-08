public import Foundation

/// Reads a Chromium profile's `Cookies` database through a private copy
/// (the browser may be running) and decrypts each value in memory.
public struct ChromiumCookieReader {
    /// Creates a reader for this browser format.
    public init() {}

    /// `crypto` is nil when the caller has no key yet; then only rows with a
    /// plaintext `value` (very old databases) are returned.
    public func read(_ database: URL, crypto: ChromiumCookieCrypto?, now: Date = Date()) throws -> CookieReadResult {
        let db = try SQLiteSnapshot(copying: database)
        let version = metaVersion(db)
        let columns = columnNames(db, table: "cookies")
        guard columns.contains("host_key"), columns.contains("encrypted_value") else {
            throw CookieImportError.malformed("cookies table")
        }
        let secure = columns.contains("is_secure") ? "is_secure" : "secure"
        let httpOnly = columns.contains("is_httponly") ? "is_httponly" : "httponly"
        let sameSite = columns.contains("samesite") ? "samesite" : "-1"
        let partition = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "''"
        let hasExpires = columns.contains("has_expires") ? "has_expires" : "1"
        let sql = """
            SELECT host_key, name, value, encrypted_value, path, expires_utc, \(secure), \(httpOnly), \(sameSite), \
            \(partition), \(hasExpires), creation_utc, last_access_utc FROM cookies
            """
        var result = CookieReadResult(cookies: [])
        try db.query(sql) { row in
            let host = row.string(0) ?? ""
            if !(row.string(9) ?? "").isEmpty {
                result.partitioned += 1
                return true
            }
            let encrypted = row.data(3) ?? Data()
            let value: String
            if encrypted.isEmpty {
                value = row.string(2) ?? ""
            } else if let crypto, let plain = try? crypto.decrypt(encrypted, hostKey: host, databaseVersion: version) {
                value = plain
            } else {
                result.undecryptable += 1
                return true
            }
            let expires = row.int64(10) != 0 ? BrowserTime().chromium(row.int64(5)) : nil
            let cookie = ImportedCookie(
                name: row.string(1) ?? "", value: value, domain: host, path: row.string(4) ?? "/",
                secure: row.int64(6) != 0, httpOnly: row.int64(7) != 0, sameSite: self.sameSite(row.int64(8)),
                expires: expires, created: BrowserTime().chromium(row.int64(11)), lastAccess: BrowserTime().chromium(row.int64(12))
            )
            if cookie.isExpired(at: now) { result.expired += 1 } else { result.cookies.append(cookie) }
            return true
        }
        // A key that decrypts none of many rows is the wrong key or format.
        if result.cookies.isEmpty, result.undecryptable > 0 { throw CookieImportError.undecryptable }
        return result
    }

    /// Chromium's `CookieSameSite`: -1 unspecified, 0 no restriction, 1 lax, 2 strict.
    func sameSite(_ raw: Int64) -> ImportedCookie.SameSite {
        switch raw {
        case 0: .none
        case 1: .lax
        case 2: .strict
        default: .unspecified
        }
    }

    func metaVersion(_ db: SQLiteSnapshot) -> Int {
        var version = 0
        try? db.query("SELECT value FROM meta WHERE key='version'") { row in
            version = Int(row.string(0) ?? "") ?? 0
            return false
        }
        return version
    }

    func columnNames(_ db: SQLiteSnapshot, table: String) -> Set<String> {
        var names: Set<String> = []
        try? db.query("PRAGMA table_info(\(table))") { row in
            if let name = row.string(1) { names.insert(name) }
            return true
        }
        return names
    }
}
