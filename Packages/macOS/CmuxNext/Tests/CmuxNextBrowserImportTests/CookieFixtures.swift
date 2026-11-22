import Foundation
import Synchronization
@testable import CmuxNextBrowserImport

/// Fixture cookie stores for each family, built in a temp home.
enum CookieFixtures {
    static let password = "fixture-safe-storage-password"

    /// A Chromium `Cookies` database at `version`, with `rows` encrypted by
    /// the fixture key (an empty `top_frame_site_key` unless given).
    static func chromium(_ file: URL, version: Int = 24, rows: [(host: String, name: String, value: String, partition: String)],
                         password: String = password) throws {
        let crypto = ChromiumCookieCrypto(safeStoragePassword: Data(password.utf8))
        var statements = [
            "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)",
            "INSERT INTO meta VALUES('version', '\(version)')",
            """
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL,
            value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL,
            is_httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
            priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL)
            """,
        ]
        let future = BrowserTime().chromiumMicroseconds(Date().addingTimeInterval(86_400 * 30))
        let created = BrowserTime().chromiumMicroseconds(Date(timeIntervalSince1970: 1_700_000_000))
        for row in rows {
            let blob = try crypto.encrypt(row.value, hostKey: row.host, databaseVersion: version).map { String(format: "%02x", $0) }.joined()
            statements.append("""
                INSERT INTO cookies VALUES(\(created), '\(row.host)', '\(row.partition)', '\(row.name)', '', X'\(blob)', '/', \(future), 1, 1,
                \(created), 1, 1, 1, 1, 2)
                """)
        }
        try FixtureHome.sqlite(file, statements)
    }

    static func firefox(_ file: URL, rows: [(host: String, name: String, value: String, attributes: String)]) throws {
        let expiry = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970)
        var statements = ["""
            CREATE TABLE moz_cookies(id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT,
            path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, isHttpOnly INTEGER,
            inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0, rawSameSite INTEGER DEFAULT 0, schemeMap INTEGER DEFAULT 0)
            """]
        for row in rows {
            statements.append("""
                INSERT INTO moz_cookies(originAttributes, name, value, host, path, expiry, lastAccessed, creationTime, isSecure, isHttpOnly, sameSite)
                VALUES('\(row.attributes)', '\(row.name)', '\(row.value)', '\(row.host)', '/', \(expiry), 1700000000000000, 1700000000000000, 0, 1, 1)
                """)
        }
        try FixtureHome.sqlite(file, statements)
    }

    /// One page of Safari binary cookies.
    static func safari(_ cookies: [(domain: String, name: String, path: String, value: String, flags: UInt32, expires: Date)]) -> Data {
        func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }
        func double(_ value: Double) -> [UInt8] { withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) } }
        var records: [[UInt8]] = []
        for cookie in cookies {
            let strings = [cookie.domain, cookie.name, cookie.path, cookie.value].map { Array($0.utf8) + [0] }
            var offsets: [UInt32] = []
            var cursor: UInt32 = 56
            for string in strings {
                offsets.append(cursor)
                cursor += UInt32(string.count)
            }
            var record = le32(cursor) + le32(0) + le32(cookie.flags) + le32(0)
            record += offsets.flatMap(le32) + [UInt8](repeating: 0, count: 8)
            record += double(cookie.expires.timeIntervalSinceReferenceDate) + double(Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate)
            record += strings.flatMap { $0 }
            records.append(record)
        }
        let headerSize = 8 + records.count * 4 + 4
        var page = be32(0x0000_0100) + le32(UInt32(records.count))
        var offset = UInt32(headerSize)
        for record in records {
            page += le32(offset)
            offset += UInt32(record.count)
        }
        page += le32(0) + records.flatMap { $0 }
        return Data("cook".utf8 + be32(1) + be32(UInt32(page.count)) + page + [UInt8](repeating: 0, count: 8))
    }
}

/// A fake cookie store: records what it was given, rejects names that
/// start with "reject".
final class RecordingCookieStore: CookieDestination {
    let received = Mutex<[String: [ImportedCookie]]>([:])

    func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
        let accepted = cookies.filter { !$0.name.hasPrefix("reject") }
        received.withLock { $0[profileID, default: []] += accepted }
        return CookieWriteResult(written: accepted.count, rejected: cookies.count - accepted.count)
    }
}
