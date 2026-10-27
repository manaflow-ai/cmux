import CmuxFuzzSupport
@testable import CmuxNextBrowserImport
import Foundation
import SQLite3

/// SQL literals for the cells of a damaged browser database: any SQLite type in any column (SQLite
/// keeps whatever a row was written with), extreme integers and times, text that is not UTF-8.
struct ImportFuzzSQL {
    static let integers: [Int64] = [
        0, 1, -1, 2, 3, 24, 255, 256, Int64(Int32.max), Int64(Int32.min), .max, .min, .max - 1,
        13_300_000_000_000_000, 1_700_000_000_000_000, 100_000_000_001, 1_700_000_000, 800_000_000,
    ]
    static let urls = [
        "https://example.com/", "http://a.example/path?q=1#f", "file:///tmp/x.html", "ftp://f.example/", "javascript:alert(1)",
        "chrome://settings", "about:blank", "", "https://", "http://[::1]:8080/", "https://bücher.example/", "HTTPS://UPPER.EXAMPLE/",
        "moz-extension://abc", "android://hash@com.example/",
    ]
    static let hosts = [".example.com", "example.com", "a.example", "", ".", "localhost", "[::1]", "bücher.example", "ex'ample.com"]
    static let alphabet: [Character] = ["a", "Z", "0", "'", "\"", " ", "/", ".", ":", "%", "{", "é", "日", "\u{1F600}", "\\", ";", "-"]

    /// A cell of any type.
    static func any(_ rng: inout FuzzRNG) -> String {
        switch rng.below(9) {
        case 0: "NULL"
        case 1: String(rng.element(of: integers) ?? 0)
        case 2: String(rng.int(in: -3...3))
        case 3: SQLiteFixture.quote(rng.element(of: urls) ?? "")
        case 4: SQLiteFixture.blob(rng.bytes(48))
        case 5: String(rng.double(in: -1e18...1e18))
        // Text that is not UTF-8: SQLite stores the bytes as they come.
        case 6: "CAST(\(SQLiteFixture.blob(rng.bytes(12))) AS TEXT)"
        case 7: "X''"
        default: SQLiteFixture.quote(rng.text(alphabet, 24))
        }
    }

    /// Usually an integer, sometimes any cell.
    static func integer(_ rng: inout FuzzRNG) -> String {
        rng.oneIn(4) ? any(&rng) : String(rng.element(of: integers) ?? 0)
    }

    /// Usually one of `choices`, sometimes any cell.
    static func text(_ rng: inout FuzzRNG, _ choices: [String]) -> String {
        rng.oneIn(4) ? any(&rng) : SQLiteFixture.quote(rng.element(of: choices) ?? "")
    }

    static func insert(_ table: String, _ row: [(String, String)]) -> String {
        "INSERT INTO \(table) (\(row.map { $0.0 }.joined(separator: ", "))) VALUES (\(row.map { $0.1 }.joined(separator: ", ")));"
    }
}

/// A database written, then sometimes damaged byte by byte: the number of rows the reader should
/// account for is the rows written, or after damage whatever SQLite itself still reads of the table.
struct ImportFuzzDatabase {
    let file: URL
    let rows: Int?
    /// Whether the file is as written and has every column the reader asks for.
    let intact: Bool

    init(_ file: URL, schema: String, inserts: [String], table: String, droppedColumn: Bool, _ rng: inout FuzzRNG) throws {
        try SQLiteFixture.create(file, schema + "\n" + inserts.joined(separator: "\n"))
        self.file = file
        if rng.oneIn(4) {
            try ImportFuzzFiles.damage(file, &rng)
            rows = SQLiteFixture.rowCount(file, table: table)
            intact = false
        } else {
            rows = inserts.count
            intact = !droppedColumn
        }
    }
}

extension SQLiteFixture {
    /// The table's rows as SQLite reads them with every column decoded; nil when it cannot.
    static func rowCount(_ file: URL, table: String) -> Int? {
        rowCount(file, query: "SELECT * FROM \(table)")
    }

    /// The rows `query` gives, every column decoded; nil when it cannot.
    static func rowCount(_ file: URL, query: String) -> Int? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true { // wakeup-allow: bounded by the table; ends at SQLITE_DONE or an error
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return count }
            guard step == SQLITE_ROW else { return nil }
            for column in 0..<sqlite3_column_count(statement) { _ = sqlite3_column_text(statement, column) }
            count += 1
        }
    }
}

/// The browser databases: each case writes one with random cells, reads it with the import's reader and
/// checks the reader's promises. Every row the reader saw is imported or counted by its skip reason.
struct ImportFuzzDatabases {
    static let now = ImportFuzzCases.now

    // MARK: Cookies

    static func chromiumCookies(_ rng: inout FuzzRNG, in directory: URL) throws {
        let modern = rng.bool()
        var columns = ["host_key", "name", "value", "encrypted_value", "path", "expires_utc",
                       modern ? "is_secure" : "secure", modern ? "is_httponly" : "httponly", "creation_utc", "last_access_utc"]
        if modern { columns += ["samesite", "top_frame_site_key", "has_expires"] }
        let dropped = rng.oneIn(12)
        if dropped { columns.remove(at: rng.below(columns.count)) }
        let versionCell = rng.oneIn(4) ? ImportFuzzSQL.any(&rng) : String(rng.element(of: [0, 18, 23, 24, 25]) ?? 24)
        let version = Int(versionCell) ?? 0
        var schema = "CREATE TABLE cookies (\(columns.joined(separator: ", ")));"
        if !rng.oneIn(6) { schema += "CREATE TABLE meta (key, value); INSERT INTO meta VALUES ('version', \(versionCell));" }
        var inserts: [String] = []
        for _ in 0..<rng.below(12) {
            let host = rng.element(of: ImportFuzzSQL.hosts) ?? ""
            let value = rng.text(ImportFuzzSQL.alphabet, 16)
            var row: [(String, String)] = []
            for column in columns {
                switch column {
                case "host_key": row.append((column, rng.oneIn(6) ? ImportFuzzSQL.any(&rng) : SQLiteFixture.quote(host)))
                case "encrypted_value": row.append((column, encryptedCookie(&rng, value: value, host: host, version: version)))
                case "value", "name", "path", "top_frame_site_key":
                    row.append((column, rng.oneIn(2) ? SQLiteFixture.quote(rng.oneIn(2) ? "" : value) : ImportFuzzSQL.any(&rng)))
                default: row.append((column, ImportFuzzSQL.integer(&rng)))
                }
            }
            inserts.append(ImportFuzzSQL.insert("cookies", row))
        }
        let database = try ImportFuzzDatabase(directory.appending(path: "Cookies"), schema: schema, inserts: inserts, table: "cookies",
                                              droppedColumn: dropped, &rng)
        let result: CookieReadResult
        do {
            result = try ChromiumCookieReader().read(database.file, crypto: ImportFuzzKeys.cookies, now: now)
        } catch let error as CookieImportError {
            try FuzzRun.check(!database.intact || error == .undecryptable, "an intact Cookies database failed: \(error)")
            return
        } catch is SQLiteSnapshot.Failure {
            try FuzzRun.check(!database.intact, "an intact Cookies database did not open")
            return
        }
        try ImportFuzzOracle.cookies(result, now: now)
        if let rows = database.rows {
            let accounted = result.cookies.count + result.undecryptable + result.partitioned + result.expired
            try FuzzRun.check(accounted == rows, "\(rows) cookie rows, \(accounted) imported or skipped")
        }
    }

    /// A sealed value, one sealed for another host, Linux's prefix, random bytes, none or NULL.
    static func encryptedCookie(_ rng: inout FuzzRNG, value: String, host: String, version: Int) -> String {
        switch rng.below(6) {
        case 0, 1: SQLiteFixture.blob((try? ImportFuzzKeys.cookies.encrypt(value, hostKey: host, databaseVersion: version)) ?? Data())
        case 2: SQLiteFixture.blob((try? ImportFuzzKeys.cookies.encrypt(value, hostKey: "other.example", databaseVersion: 24)) ?? Data())
        case 3: SQLiteFixture.blob(Data("v11".utf8) + rng.bytes(40))
        case 4: rng.bool() ? "X''" : "NULL"
        default: SQLiteFixture.blob(Data("v10".utf8) + rng.bytes(64))
        }
    }

    static func firefoxCookies(_ rng: inout FuzzRNG, in directory: URL) throws {
        var columns = ["host", "name", "value", "path", "expiry", "isSecure", "isHttpOnly", "creationTime", "lastAccessed"]
        if rng.bool() { columns += ["sameSite", "originAttributes"] }
        let dropped = rng.oneIn(12)
        if dropped { columns.remove(at: rng.below(columns.count)) }
        var inserts: [String] = []
        for _ in 0..<rng.below(12) {
            let row = columns.map { column -> (String, String) in
                switch column {
                case "host": (column, ImportFuzzSQL.text(&rng, ImportFuzzSQL.hosts))
                case "name", "value", "path": (column, SQLiteFixture.quote(rng.text(ImportFuzzSQL.alphabet, 12)))
                case "originAttributes": (column, ImportFuzzSQL.text(&rng, ["", "^userContextId=1", "^partitionKey=%28https%2Cexample.com%29"]))
                default: (column, ImportFuzzSQL.integer(&rng))
                }
            }
            inserts.append(ImportFuzzSQL.insert("moz_cookies", row))
        }
        let database = try ImportFuzzDatabase(directory.appending(path: "cookies.sqlite"), schema: "CREATE TABLE moz_cookies (\(columns.joined(separator: ", ")));",
                                              inserts: inserts, table: "moz_cookies", droppedColumn: dropped, &rng)
        let result: CookieReadResult
        do {
            result = try FirefoxCookieReader().read(database.file, now: now)
        } catch is CookieImportError {
            try FuzzRun.check(!database.intact, "an intact cookies.sqlite failed")
            return
        } catch is SQLiteSnapshot.Failure {
            try FuzzRun.check(!database.intact, "an intact cookies.sqlite did not open")
            return
        }
        try ImportFuzzOracle.cookies(result, now: now)
        if let rows = database.rows {
            let accounted = result.cookies.count + result.partitioned + result.expired
            try FuzzRun.check(accounted == rows, "\(rows) cookie rows, \(accounted) imported or skipped")
        }
    }

    // MARK: Profile list

    /// A damaged `Local State` over profile folders that may or may not be there: every entry is a folder
    /// that exists, listed once.
    static func chromiumLocalState(_ rng: inout FuzzRNG, in directory: URL) throws {
        var present: [String] = []
        for name in ProfileListFixture.folders where !rng.oneIn(4) {
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appending(path: "Preferences"))
            present.append(name)
        }
        let seed = rng.oneIn(4)
        let state = seed ? ProfileListFixture.localState
            : FuzzMutator(dictionary: ImportFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 4096).mutate(ProfileListFixture.localState, using: &rng)
        try state.write(to: directory.appending(path: "Local State"))
        let entries = ChromiumProfileList().entries(in: directory)
        let names = entries.map(\.directoryName)
        try FuzzRun.check(Set(names).count == names.count, "a profile listed twice: \(names)")
        for name in names {
            try FuzzRun.check(FileManager.default.fileExists(atPath: directory.appending(path: name).path), "profile \(name) is not a folder")
        }
        if seed {
            let expected = ["Profile 1", "Default", "Profile 9223372036854775807"].filter(present.contains)
            try FuzzRun.check(names == expected, "the Local State seed listed \(names), expected \(expected)")
        }
    }

    // MARK: History and bookmarks

    static func chromiumHistory(_ rng: inout FuzzRNG, in directory: URL) throws {
        var columns = ["url", "title", "visit_count", "typed_count", "last_visit_time", "hidden"]
        let dropped = rng.oneIn(12)
        if dropped { columns.remove(at: rng.below(columns.count)) }
        var inserts: [String] = []
        for _ in 0..<rng.below(16) {
            let row = columns.map { column -> (String, String) in
                switch column {
                case "url": (column, ImportFuzzSQL.text(&rng, ImportFuzzSQL.urls))
                case "title": (column, ImportFuzzSQL.any(&rng))
                case "hidden": (column, rng.oneIn(3) ? ImportFuzzSQL.any(&rng) : "0")
                default: (column, ImportFuzzSQL.integer(&rng))
                }
            }
            inserts.append(ImportFuzzSQL.insert("urls", row))
        }
        let database = try ImportFuzzDatabase(directory.appending(path: "History"), schema: "CREATE TABLE urls (\(columns.joined(separator: ", ")));",
                                              inserts: inserts, table: "urls", droppedColumn: dropped, &rng)
        let limit = rng.int(in: -1...20)
        let read: ImportRead<ImportedHistoryEntry>
        do {
            read = try ChromiumHistoryReader().read(database.file, limit: limit)
        } catch is SQLiteSnapshot.Failure {
            try FuzzRun.check(!database.intact, "an intact History database failed")
            return
        }
        try ImportFuzzOracle.history(read.items, limit: limit)
        let pages = "SELECT * FROM urls WHERE hidden = 0 AND visit_count > 0"
        try accountsForPages(read, database.file, limit: limit, pages: pages,
                             kept: pages + " AND \(ImportableURL.sqlFilter("url")) AND \(BrowserTime.sqlKept("last_visit_time", last: BrowserTime.lastChromium))",
                             "History")
    }

    /// Every visited page is imported or counted by its skip reason; only pages past `limit` are
    /// neither. `pages` selects every page the reader looks at, `kept` those it would import.
    static func accountsForPages(_ read: ImportRead<ImportedHistoryEntry>, _ file: URL, limit: Int, pages: String, kept: String,
                                 _ what: String) throws {
        guard let all = SQLiteFixture.rowCount(file, query: pages), let wanted = SQLiteFixture.rowCount(file, query: kept) else { return }
        let expected = all - wanted + min(wanted, max(0, limit))
        try FuzzRun.check(read.items.count + read.skipped.total == expected,
                          "\(what): \(all) pages, \(wanted) importable, limit \(limit): \(read.items.count) imported and \(read.skipped) skipped")
    }

    static func safariHistory(_ rng: inout FuzzRNG, in directory: URL) throws {
        var inserts: [String] = []
        let items = rng.below(8)
        for id in 0..<items {
            inserts.append(ImportFuzzSQL.insert("history_items", [("id", String(id)), ("url", ImportFuzzSQL.text(&rng, ImportFuzzSQL.urls)),
                                                                  ("visit_count", ImportFuzzSQL.integer(&rng))]))
        }
        for _ in 0..<rng.below(16) {
            inserts.append(ImportFuzzSQL.insert("history_visits", [("history_item", rng.oneIn(5) ? ImportFuzzSQL.any(&rng) : String(rng.below(items + 1))),
                                                                   ("visit_time", rng.oneIn(3) ? ImportFuzzSQL.any(&rng) : String(rng.double(in: -1e12...1e12))),
                                                                   ("title", ImportFuzzSQL.any(&rng))]))
        }
        let schema = "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url, visit_count); CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item, visit_time, title);"
        let database = try ImportFuzzDatabase(directory.appending(path: "History.db"), schema: schema, inserts: inserts, table: "history_items",
                                              droppedColumn: false, &rng)
        let limit = rng.int(in: 0...20)
        let read: ImportRead<ImportedHistoryEntry>
        do {
            read = try SafariHistoryReader().read(database.file, limit: limit)
        } catch is SQLiteSnapshot.Failure {
            try FuzzRun.check(!database.intact, "an intact History.db failed")
            return
        }
        try ImportFuzzOracle.history(read.items, limit: limit)
        // Every item is a page, visited or not.
        let kept = """
            SELECT i.id, MAX(v.visit_time) AS last FROM history_items i JOIN history_visits v ON v.history_item = i.id
            WHERE \(ImportableURL.sqlFilter("i.url")) GROUP BY i.id HAVING \(BrowserTime.sqlKept("last", last: BrowserTime.lastCocoa))
            """
        try accountsForPages(read, database.file, limit: limit, pages: "SELECT * FROM history_items", kept: kept, "History.db")
    }

    /// Bookmarks whose folders name any parent (themselves, each other, none), and history.
    static func firefoxPlaces(_ rng: inout FuzzRNG, in directory: URL) throws {
        let guids = ["root________", "toolbar_____", "menu________", "unfiled_____", "mobile______", "tags________", "abcdefghijkl", ""]
        var inserts: [String] = []
        let places = rng.below(8)
        for id in 0..<places {
            inserts.append(ImportFuzzSQL.insert("moz_places", [("id", String(id)), ("url", ImportFuzzSQL.text(&rng, ImportFuzzSQL.urls)),
                                                               ("title", ImportFuzzSQL.any(&rng)), ("visit_count", ImportFuzzSQL.integer(&rng)),
                                                               ("last_visit_date", ImportFuzzSQL.integer(&rng)), ("hidden", rng.oneIn(4) ? "1" : "0")]))
        }
        let marks = rng.below(16)
        for id in 0..<marks {
            inserts.append(ImportFuzzSQL.insert("moz_bookmarks", [
                ("id", String(id)), ("type", rng.oneIn(6) ? ImportFuzzSQL.any(&rng) : String(1 + rng.below(3))),
                ("fk", rng.oneIn(5) ? ImportFuzzSQL.any(&rng) : String(rng.below(places + 1))),
                ("parent", rng.oneIn(5) ? ImportFuzzSQL.any(&rng) : String(rng.below(marks + 1))),
                ("position", ImportFuzzSQL.integer(&rng)), ("title", ImportFuzzSQL.any(&rng)),
                ("dateAdded", ImportFuzzSQL.integer(&rng)), ("guid", ImportFuzzSQL.text(&rng, guids)),
            ]))
        }
        let schema = """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url, title, visit_count, last_visit_date, hidden);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type, fk, parent, position, title, dateAdded, guid);
            """
        let database = try ImportFuzzDatabase(directory.appending(path: "places.sqlite"), schema: schema, inserts: inserts, table: "moz_bookmarks",
                                              droppedColumn: false, &rng)
        do {
            let read = try FirefoxPlacesReader().readBookmarks(database.file)
            try ImportFuzzOracle.bookmarks(read.items)
            // Every bookmark row is imported or counted, but a tag assignment (under the tags root) is
            // neither: it is no bookmark. Only the fixture's own tags folder can make one.
            if let rows = SQLiteFixture.rowCount(database.file, query: "SELECT * FROM moz_bookmarks WHERE type = 1") {
                let accounted = read.items.count + read.skipped.total
                let tags = inserts.contains { $0.contains("'tags________'") }
                try FuzzRun.check(tags ? accounted <= rows : accounted == rows,
                                  "\(rows) bookmark rows gave \(read.items.count) bookmarks and \(read.skipped) skipped")
            }
        } catch is SQLiteSnapshot.Failure {
            try FuzzRun.check(!database.intact, "an intact places.sqlite gave no bookmarks")
        }
        let limit = rng.int(in: 0...20)
        do {
            let read = try FirefoxPlacesReader().readHistory(database.file, limit: limit)
            try ImportFuzzOracle.history(read.items, limit: limit)
            let pages = "SELECT * FROM moz_places WHERE hidden = 0 AND visit_count > 0"
            try accountsForPages(read, database.file, limit: limit, pages: pages,
                                 kept: pages + " AND \(ImportableURL.sqlFilter("url")) AND \(BrowserTime.sqlKept("last_visit_date", last: BrowserTime.lastMozilla))",
                                 "places.sqlite")
        } catch is SQLiteSnapshot.Failure {
            try FuzzRun.check(!database.intact, "an intact places.sqlite gave no history")
        }
    }

    // MARK: Passwords

    #if !CMUX_NO_PASSWORD_IMPORT
    /// `Login Data` and `Login Data For Account`: every row is a sign-in or a counted skip.
    static func chromiumLogins(_ rng: inout FuzzRNG, in directory: URL) throws {
        let realms = ["https://example.com/", "http://a.example/", "android://hash@com.example/", "https://example.com", "", "httpx", "http"]
        var expected: Int? = 0
        var intact = true
        for name in ChromiumLoginDataReader.files where !rng.oneIn(3) {
            var columns = ["origin_url", "signon_realm", "username_value", "password_value", "date_created", "blacklisted_by_user", "scheme",
                           "federation_url"]
            let dropped = rng.oneIn(16)
            if dropped { columns.remove(at: rng.below(columns.count)) }
            var inserts: [String] = []
            for _ in 0..<rng.below(10) {
                let row = columns.map { column -> (String, String) in
                    switch column {
                    case "signon_realm": (column, ImportFuzzSQL.text(&rng, realms))
                    case "origin_url": (column, ImportFuzzSQL.text(&rng, ImportFuzzSQL.urls))
                    case "username_value": (column, ImportFuzzSQL.text(&rng, ["ann", "bob", "", "ann"]))
                    case "password_value": (column, sealedPassword(&rng))
                    case "federation_url": (column, rng.oneIn(4) ? ImportFuzzSQL.any(&rng) : "''")
                    case "blacklisted_by_user", "scheme": (column, rng.oneIn(4) ? ImportFuzzSQL.integer(&rng) : "0")
                    default: (column, ImportFuzzSQL.integer(&rng))
                    }
                }
                inserts.append(ImportFuzzSQL.insert("logins", row))
            }
            let database = try ImportFuzzDatabase(directory.appending(path: name), schema: "CREATE TABLE logins (\(columns.joined(separator: ", ")));",
                                                  inserts: inserts, table: "logins", droppedColumn: dropped, &rng)
            intact = intact && database.intact
            expected = expected.flatMap { sum in database.rows.map { sum + $0 } }
        }
        let read: (logins: [ImportedLogin], skipped: LoginSkipCounts)
        do {
            read = try ChromiumLoginDataReader().read(profile: directory, crypto: ImportFuzzKeys.passwords)
        } catch is SQLiteSnapshot.Failure {
            try FuzzRun.check(!intact, "intact Login Data failed")
            return
        }
        if let expected {
            try FuzzRun.check(read.logins.count + read.skipped.total == expected,
                              "\(expected) login rows gave \(read.logins.count) sign-ins and \(read.skipped.total) skipped")
        }
        for login in read.logins {
            try FuzzRun.check(!login.password.isEmpty && login.signonRealm.hasPrefix("http"), "a sign-in with no password or a non-web realm")
            try ImportFuzzOracle.fits(login.created, "a sign-in")
        }
    }

    static func sealedPassword(_ rng: inout FuzzRNG) -> String {
        switch rng.below(6) {
        case 0, 1:
            let secret = SecretBytes(copying: Array(rng.text(ImportFuzzSQL.alphabet, 12).utf8))
            return SQLiteFixture.blob((try? ImportFuzzKeys.passwords.encrypt(secret)) ?? Data())
        case 2: return SQLiteFixture.blob((try? ImportFuzzKeys.passwords.encrypt(SecretBytes(copying: [0xFF, 0xFE, 0x80]))) ?? Data())
        case 3: return SQLiteFixture.blob(Data("v10".utf8) + rng.bytes(40))
        case 4: return rng.bool() ? "X''" : "NULL"
        default: return ImportFuzzSQL.any(&rng)
        }
    }

    /// `key4.db` and `logins.json`: a damaged entry is skipped and counted; only a damaged store fails.
    static func firefoxLogins(_ rng: inout FuzzRNG, in directory: URL) throws {
        let keyStore = rng.below(8)
        let length = rng.below(80)
        let junk = rng.bytes(count: length)
        switch keyStore {
        case 0: try FirefoxKeyFixture.key4(directory.appending(path: "key4.db"), check: junk)
        case 1: try FirefoxKeyFixture.key4(directory.appending(path: "key4.db"), sealedKey: junk)
        default: try FirefoxKeyFixture.key4(directory.appending(path: "key4.db"))
        }
        var keyIntact = keyStore > 1
        if rng.oneIn(8) {
            try ImportFuzzFiles.damage(directory.appending(path: "key4.db"), &rng)
            keyIntact = false
        }
        let hosts = ["https://example.com", "http://a.example:8080", "https://bücher.example", "moz-extension://abc", "chrome://x", "", "https://"]
        var entries: [[String: Any]] = []
        var decodable = true
        for _ in 0..<rng.below(10) {
            var entry: [String: Any] = [
                "hostname": rng.element(of: hosts) ?? "",
                "encryptedUsername": try sealedLogin(&rng),
                "encryptedPassword": try sealedLogin(&rng),
            ]
            if rng.oneIn(4) { entry["httpRealm"] = rng.bool() ? "Realm" : NSNull() }
            if !rng.oneIn(4) { entry["timeCreated"] = rng.element(of: [1.7e12, 0, -1, 1e300, -1e300, 9.3e18, 1.5]) ?? 0 }
            if rng.oneIn(24) {
                entry.removeValue(forKey: rng.element(of: ["hostname", "encryptedUsername", "encryptedPassword"]) ?? "hostname")
                decodable = false
            }
            entries.append(entry)
        }
        let logins = directory.appending(path: "logins.json")
        try JSONSerialization.data(withJSONObject: ["logins": entries]).write(to: logins)
        if rng.oneIn(6) {
            try ImportFuzzFiles.damage(logins, &rng)
            decodable = false
        }
        let read: (logins: [ImportedLogin], skipped: LoginSkipCounts)
        do {
            read = try FirefoxLoginReader().read(profile: directory, primaryPassword: nil)
        } catch {
            try FuzzRun.check(!(keyIntact && decodable), "an intact key store and logins.json failed: \(error)")
            return
        }
        if decodable {
            try FuzzRun.check(read.logins.count + read.skipped.total == entries.count,
                              "\(entries.count) logins gave \(read.logins.count) sign-ins and \(read.skipped.total) skipped")
        }
        for login in read.logins {
            try FuzzRun.check(!login.password.isEmpty && login.signonRealm.hasPrefix("http"), "a sign-in with no password or a non-web realm")
            try ImportFuzzOracle.fits(login.created, "a sign-in")
        }
    }

    /// A value the store opens, an empty one, one that is not UTF-8, damaged DER, base64 of nothing, not base64.
    static func sealedLogin(_ rng: inout FuzzRNG) throws -> String {
        switch rng.below(7) {
        case 0, 1: return try FirefoxKeyFixture.seal(Array(rng.text(ImportFuzzSQL.alphabet, 12).utf8))
        case 2: return try FirefoxKeyFixture.seal([])
        case 3: return try FirefoxKeyFixture.seal([0xFF, 0xFE, 0x80])
        case 4:
            let sealed = Data(base64Encoded: try FirefoxKeyFixture.seal(Array("pw".utf8))) ?? Data()
            return FuzzMutator(maximumCount: 512).mutate(sealed, using: &rng).base64EncodedString()
        case 5: return rng.bytes(64).base64EncodedString()
        default: return "not base64 \(rng.below(100))"
        }
    }
    #endif
}

#if !CMUX_NO_PASSWORD_IMPORT
/// A Firefox key store whose primary password is empty, as NSS writes it (PBES2 with
/// PBKDF2-HMAC-SHA256 and AES-256-CBC), holding one master key; `seal` encrypts a logins.json value
/// under that key.
struct FirefoxKeyFixture {
    static let globalSalt = [UInt8](repeating: 0x11, count: 20)
    static let keyID = [UInt8](repeating: 0xF8, count: 16)
    static let master: [UInt8] = (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }

    /// A key4.db item that the empty primary password opens to `plain`.
    static func item(_ plain: [UInt8]) throws -> [UInt8] {
        let entrySalt = [UInt8](repeating: 0x22, count: 32)
        let iv = [UInt8](repeating: 0x33, count: 14)
        let hashed = FirefoxPasswordCrypto.sha1([globalSalt], secret: SecretBytes(capacity: 0) { _ in 0 })
        guard let key = ImportCrypto.pbkdf2(.sha256, password: hashed, salt: entrySalt, rounds: 1, keyLength: ImportCrypto.aes256KeySize)
        else { throw FirefoxPasswordCrypto.Failure.undecryptable }
        let sealed = try FirefoxPasswordCrypto.crypt(.aes, key: key, keyLength: ImportCrypto.aes256KeySize,
                                                    iv: [NSSDER.octetString, 14] + iv, plain, operation: .encrypt)
        let pbkdf2 = NSSFixture.sequence(
            NSSFixture.oid(FirefoxPasswordCrypto.pbkdf2),
            NSSFixture.sequence(NSSFixture.octets(entrySalt), NSSFixture.integer(1), NSSFixture.integer(ImportCrypto.aes256KeySize),
                                NSSFixture.sequence(NSSFixture.oid(FirefoxPasswordCrypto.hmacSHA256))))
        let cipher = NSSFixture.sequence(NSSFixture.oid(FirefoxPasswordCrypto.aes256CBC), NSSFixture.octets(iv))
        return NSSFixture.sequence(
            NSSFixture.sequence(NSSFixture.oid(FirefoxPasswordCrypto.pbes2), NSSFixture.sequence(pbkdf2, cipher)),
            NSSFixture.octets(sealed.withUnsafeBytes { Array($0) }))
    }

    /// key4.db with the password check and the master key; `check` or `sealedKey` replace their items.
    static func key4(_ file: URL, check: [UInt8]? = nil, sealedKey: [UInt8]? = nil) throws {
        let checkItem = try check ?? item(Array("password-check".utf8))
        let keyItem = try sealedKey ?? item(master)
        try SQLiteFixture.create(file, """
            CREATE TABLE metaData (id, item1, item2);
            INSERT INTO metaData VALUES ('password', \(SQLiteFixture.blob(Data(globalSalt))), \(SQLiteFixture.blob(Data(checkItem))));
            CREATE TABLE nssPrivate (a11, a102);
            INSERT INTO nssPrivate VALUES (\(SQLiteFixture.blob(Data(keyItem))), \(SQLiteFixture.blob(Data(keyID))));
            """)
    }

    /// A logins.json value: base64 DER {key id, {AES-256-CBC, IV}, ciphertext} under the master key.
    static func seal(_ plain: [UInt8]) throws -> String {
        let iv = [UInt8](repeating: 0x44, count: ImportCrypto.Cipher.aes.blockSize)
        let sealed = try FirefoxPasswordCrypto.crypt(.aes, key: SecretBytes(copying: master), keyLength: ImportCrypto.aes256KeySize,
                                                    iv: iv, plain, operation: .encrypt)
        let der = NSSFixture.sequence(
            NSSFixture.octets(keyID),
            NSSFixture.sequence(NSSFixture.oid(FirefoxPasswordCrypto.aes256CBC), NSSFixture.octets(iv)),
            NSSFixture.octets(sealed.withUnsafeBytes { Array($0) }))
        return Data(der).base64EncodedString()
    }
}
#endif
