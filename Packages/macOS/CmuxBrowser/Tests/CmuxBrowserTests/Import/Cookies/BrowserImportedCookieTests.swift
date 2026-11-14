import Foundation
import SQLite3
import Testing
@testable import CmuxBrowser

@Suite("Imported browser cookies")
struct BrowserImportedCookieTests {
    // 2027-11-08T15:54:15.176Z in milliseconds, as current Firefox-family cookie databases store it.
    private let expiryMilliseconds: Int64 = 1_825_694_055_176
    private let expiryDate = Date(timeIntervalSince1970: 1_825_694_055.176)
    // 2023-11-14, before every fixture expiry.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func firefoxRow(
        expiry: Int64 = 1_825_694_055_176,
        isHTTPOnly: Bool = false,
        sameSite: Int64 = 0,
        originAttributes: String = "",
        schemaVersion: Int64 = 17,
        now: Date? = nil
    ) -> BrowserImportedCookie? {
        BrowserImportedCookie.firefox(
            host: ".example.test",
            name: "session",
            value: "abc",
            path: "/",
            expiry: expiry,
            isSecure: true,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite,
            originAttributes: originAttributes,
            schemaVersion: schemaVersion,
            now: now ?? self.now
        )
    }

    private func chromiumRow(
        expiresUTC: Int64 = 13_407_167_655_176_000,
        isHTTPOnly: Bool = false,
        sameSite: Int64 = -1,
        topFrameSiteKey: String = ""
    ) -> BrowserImportedCookie? {
        BrowserImportedCookie.chromium(
            host: ".example.test",
            name: "session",
            value: "abc",
            path: "/",
            expiresUTC: expiresUTC,
            isSecure: true,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite,
            topFrameSiteKey: topFrameSiteKey,
            now: now
        )
    }

    @Test("reads a Firefox expiry stored in milliseconds")
    func firefoxMillisecondExpiry() throws {
        let cookie = try #require(firefoxRow(expiry: expiryMilliseconds))
        let expires = try #require(cookie.expiresDate)
        #expect(abs(expires.timeIntervalSince(expiryDate)) < 1)
    }

    @Test("reads a Firefox expiry stored in seconds by cookie schema 15 and older")
    func firefoxSecondExpiry() throws {
        let cookie = try #require(firefoxRow(expiry: 1_825_694_055, schemaVersion: 15))
        let expires = try #require(cookie.expiresDate)
        #expect(abs(expires.timeIntervalSince(expiryDate)) < 1)
    }

    @Test("reads a long-expired millisecond expiry as milliseconds")
    func firefoxSmallMillisecondExpiry() throws {
        let cookie = try #require(firefoxRow(expiry: 2_000_000_000, schemaVersion: 16, now: Date(timeIntervalSince1970: 0)))
        let expires = try #require(cookie.expiresDate)
        #expect(abs(expires.timeIntervalSince1970 - 2_000_000) < 1)
    }

    @Test("does not import an expired Firefox cookie", arguments: [Int64(0), -1, 1_600_000_000_000])
    func firefoxExpiredSkipped(expiry: Int64) {
        #expect(firefoxRow(expiry: expiry) == nil)
    }

    @Test("does not import an expired Chromium cookie, and keeps a session cookie")
    func chromiumExpiredSkipped() {
        // 2020-09-13 in microseconds since 1601.
        #expect(chromiumRow(expiresUTC: 13_244_473_600_000_000) == nil)
        #expect(chromiumRow(expiresUTC: 0)?.expiresDate == nil)
        #expect(chromiumRow(expiresUTC: 0) != nil)
    }

    @Test("keeps a Firefox cookie HttpOnly")
    func firefoxHTTPOnly() throws {
        let cookie = try #require(firefoxRow(isHTTPOnly: true)?.makeHTTPCookie())
        #expect(cookie.isHTTPOnly)
    }

    @Test("keeps a Firefox cookie's SameSite attribute", arguments: [
        (Int64(0), BrowserImportedCookie.SameSite.none),
        (Int64(1), BrowserImportedCookie.SameSite.lax),
        (Int64(2), BrowserImportedCookie.SameSite.strict),
        (Int64(256), BrowserImportedCookie.SameSite.none),
    ])
    func firefoxSameSite(raw: Int64, expected: BrowserImportedCookie.SameSite) throws {
        let cookie = try #require(firefoxRow(sameSite: raw))
        #expect(cookie.sameSite == expected)
    }

    @Test("does not import a partitioned Firefox cookie as a first-party cookie")
    func firefoxPartitionedSkipped() {
        #expect(firefoxRow(originAttributes: "^partitionKey=%28https%2Cembedder.test%29") == nil)
        #expect(firefoxRow(originAttributes: "^userContextId=2&partitionKey=%28https%2Cembedder.test%29") == nil)
    }

    @Test("does not import a first-party-isolated Firefox cookie as an ordinary cookie")
    func firefoxFirstPartyIsolatedSkipped() {
        #expect(firefoxRow(originAttributes: "^firstPartyDomain=embedder.test") == nil)
    }

    // Cookie schema 8 added `originAttributes`, and schema 9 `sameSite`.
    @Test("reads a Firefox moz_cookies table with or without sameSite and originAttributes", arguments: [
        "sameSite INTEGER DEFAULT 0, originAttributes TEXT NOT NULL DEFAULT '',",
        "",
    ])
    func firefoxCookiesQuery(newerColumns: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(":memory:", &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE moz_cookies (
            id INTEGER PRIMARY KEY, \(newerColumns) name TEXT, value TEXT, host TEXT, path TEXT,
            expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER
        );
        INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure, isHttpOnly)
        VALUES ('session', 'abc', '.example.test', '/', 1825694055, 1, 1);
        PRAGMA user_version = 7;
        """
        try #require(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
        let columns = try tableColumns(database, table: "moz_cookies")

        var statement: OpaquePointer?
        let query = BrowserImportedCookie.firefoxCookiesQuery(columns: columns)
        try #require(sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_count(statement) == 10)
        #expect(sqlite3_column_int64(statement, 7) == 0)
        #expect(String(cString: sqlite3_column_text(statement, 8)).isEmpty)
        #expect(sqlite3_column_int64(statement, 9) == 7)
    }

    private func tableColumns(_ database: OpaquePointer?, table: String) throws -> Set<String> {
        var columns: Set<String> = []
        var info: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, "SELECT name FROM pragma_table_info('\(table)')", -1, &info, nil) == SQLITE_OK)
        defer { sqlite3_finalize(info) }
        while sqlite3_step(info) == SQLITE_ROW {
            columns.insert(String(cString: sqlite3_column_text(info, 0)))
        }
        return columns
    }

    @Test("imports only the cookies of the selected Firefox containers", arguments: [
        ("", [0], true),
        ("", [6], false),
        ("", [6, 7], false),
        ("^userContextId=6", [0], false),
        ("^userContextId=6", [6], true),
        ("^userContextId=6", [7], false),
        ("^userContextId=7", [0, 6, 7], true),
        ("^userContextId=16", [6], false),
        ("^userContextId=%37", [7], true),
    ] as [(String, Set<Int>, Bool)])
    func firefoxContainer(originAttributes: String, containerIDs: Set<Int>, imported: Bool) {
        let cookie = BrowserImportedCookie.firefox(
            host: ".example.test",
            name: "session",
            value: "abc",
            path: "/",
            expiry: expiryMilliseconds,
            isSecure: true,
            isHTTPOnly: false,
            sameSite: 0,
            originAttributes: originAttributes,
            schemaVersion: 17,
            containerIDs: containerIDs,
            now: now
        )
        #expect((cookie != nil) == imported)
    }

    @Test("keeps a Chromium cookie HttpOnly")
    func chromiumHTTPOnly() throws {
        let cookie = try #require(chromiumRow(isHTTPOnly: true)?.makeHTTPCookie())
        #expect(cookie.isHTTPOnly)
    }

    @Test("keeps a Chromium cookie's SameSite attribute", arguments: [
        (Int64(-1), BrowserImportedCookie.SameSite.none),
        (Int64(0), BrowserImportedCookie.SameSite.none),
        (Int64(1), BrowserImportedCookie.SameSite.lax),
        (Int64(2), BrowserImportedCookie.SameSite.strict),
    ])
    func chromiumSameSite(raw: Int64, expected: BrowserImportedCookie.SameSite) throws {
        let cookie = try #require(chromiumRow(sameSite: raw))
        #expect(cookie.sameSite == expected)
    }

    @Test("does not import a partitioned Chromium cookie as a first-party cookie")
    func chromiumPartitionedSkipped() {
        #expect(chromiumRow(topFrameSiteKey: "https://embedder.test") == nil)
    }

    // Cookie schema 15 (2021) added `top_frame_site_key`.
    @Test("reads a Chromium cookies table with or without top_frame_site_key", arguments: [
        "top_frame_site_key TEXT NOT NULL DEFAULT '',",
        "",
    ])
    func chromiumCookiesQuery(topFrameSiteKeyColumn: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(":memory:", &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE cookies (
            host_key TEXT, \(topFrameSiteKeyColumn) name TEXT, value TEXT, encrypted_value BLOB,
            path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER
        );
        INSERT INTO cookies (host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite)
        VALUES ('.example.test', 'session', 'abc', x'', '/', 0, 1, 1, 1);
        """
        try #require(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
        let columns = try tableColumns(database, table: "cookies")

        var statement: OpaquePointer?
        let query = BrowserImportedCookie.chromiumCookiesQuery(columns: columns)
        try #require(sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_count(statement) == 10)
        #expect(String(cString: sqlite3_column_text(statement, 9)).isEmpty)
    }

    @Test("writes SameSite to the WebKit cookie", arguments: [
        (BrowserImportedCookie.SameSite.lax, false),
        (BrowserImportedCookie.SameSite.strict, false),
        (BrowserImportedCookie.SameSite.lax, true),
    ])
    func httpCookieSameSite(sameSite: BrowserImportedCookie.SameSite, isHTTPOnly: Bool) throws {
        let imported = BrowserImportedCookie(
            domain: ".example.test",
            name: "session",
            value: "abc",
            path: "/",
            expiresDate: expiryDate,
            isSecure: true,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite
        )
        let cookie = try #require(imported.makeHTTPCookie())
        let expected: HTTPCookieStringPolicy = sameSite == .strict ? .sameSiteStrict : .sameSiteLax
        #expect(cookie.sameSitePolicy == expected)
        #expect(cookie.isHTTPOnly == isHTTPOnly)
        #expect(cookie.domain == ".example.test")
        #expect(cookie.isSecure)
    }

    @Test("leaves a cookie with no SameSite attribute without a policy")
    func httpCookieNoSameSite() throws {
        let cookie = try #require(firefoxRow(sameSite: 0)?.makeHTTPCookie())
        #expect(cookie.sameSitePolicy == nil)
        #expect(!cookie.isHTTPOnly)
    }
}
