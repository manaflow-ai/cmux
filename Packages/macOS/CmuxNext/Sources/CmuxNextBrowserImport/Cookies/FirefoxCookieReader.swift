public import Foundation

/// Reads Firefox's `cookies.sqlite` (`moz_cookies`, values in plain text)
/// through a private copy. Cookies with origin attributes (containers,
/// partitioned cookies, private browsing) are counted and left out.
public struct FirefoxCookieReader {
    /// Creates a reader for this browser format.
    public init() {}

    public func read(_ database: URL, now: Date = Date()) throws -> CookieReadResult {
        let db = try SQLiteSnapshot(copying: database)
        let columns = ChromiumCookieReader().columnNames(db, table: "moz_cookies")
        guard columns.contains("host"), columns.contains("value") else { throw CookieImportError.malformed("moz_cookies") }
        let attributes = columns.contains("originAttributes") ? "originAttributes" : "''"
        let sameSite = columns.contains("sameSite") ? "sameSite" : "0"
        var result = CookieReadResult(cookies: [])
        let sql = "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(sameSite), \(attributes), creationTime, lastAccessed FROM moz_cookies"
        try db.query(sql) { row in
            guard (row.string(8) ?? "").isEmpty else {
                result.partitioned += 1
                return true
            }
            let cookie = ImportedCookie(
                name: row.string(1) ?? "", value: row.string(2) ?? "", domain: row.string(0) ?? "", path: row.string(3) ?? "/",
                secure: row.int64(5) != 0, httpOnly: row.int64(6) != 0, sameSite: self.sameSite(row.int64(7)),
                expires: self.expiry(row.int64(4)), created: BrowserTime().mozilla(row.int64(9)), lastAccess: BrowserTime().mozilla(row.int64(10))
            )
            if cookie.isExpired(at: now) { result.expired += 1 } else { result.cookies.append(cookie) }
            return true
        }
        return result
    }

    /// `expiry` is seconds since 1970; Firefox 135+ writes milliseconds.
    func expiry(_ raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? Double(raw) / 1000 : Double(raw))
    }

    /// Firefox's `nsICookie.sameSite`: 0 none, 1 lax, 2 strict (256 is
    /// "unset" in newer builds).
    func sameSite(_ raw: Int64) -> ImportedCookie.SameSite {
        switch raw {
        case 0: .none
        case 1: .lax
        case 2: .strict
        default: .unspecified
        }
    }
}
