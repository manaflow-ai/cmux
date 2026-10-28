import CmuxFuzzSupport
@testable import CmuxNextBrowserImport
import Foundation

/// What every import reader promises for any input: it returns or throws its own error, and what it
/// returns is safe to hand on. URLs are web pages or files (``ImportableURL``), dates fit Chromium's
/// base::Time (the password store and the bookmark export turn them into Int64 microseconds since
/// 1601), visit counts fit Chromium's `int`, and each item it read is imported or counted as skipped.
struct ImportFuzzOracle {
    static func fits(_ date: Date?, _ what: @autoclosure () -> String) throws {
        guard let date else { return }
        let microseconds = (date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        try FuzzRun.check(microseconds.isFinite && abs(microseconds) < 9.2e18,
                          "\(what()) at \(date.timeIntervalSince1970) s does not fit base::Time")
    }

    static func importable(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        try FuzzRun.check(["http", "https", "file", "ftp"].contains(scheme), "an imported URL has scheme '\(scheme)'")
    }

    static func bookmarks(_ bookmarks: [ImportedBookmark]) throws {
        for bookmark in bookmarks {
            try importable(bookmark.url)
            try fits(bookmark.dateAdded, "a bookmark")
        }
    }

    static func history(_ entries: [ImportedHistoryEntry], limit: Int) throws {
        try FuzzRun.check(entries.count <= max(limit, 0), "\(entries.count) history entries over the limit \(limit)")
        for entry in entries {
            try importable(entry.url)
            try fits(entry.lastVisit, "a visit")
            try FuzzRun.check((0...ImportedHistoryEntry.maximumVisitCount).contains(entry.visitCount),
                              "a visit count of \(entry.visitCount)")
        }
    }

    static func tabs(_ tabs: [ImportedTab]) throws {
        for tab in tabs {
            try importable(tab.url)
            try FuzzRun.check(tab.window >= 0, "a tab in window \(tab.window)")
        }
    }

    static func cookies(_ result: CookieReadResult, now: Date) throws {
        for cookie in result.cookies {
            try FuzzRun.check(!cookie.isExpired(at: now), "an expired cookie was kept")
            try fits(cookie.expires, "a cookie expiry")
            try fits(cookie.created, "a cookie creation")
            try fits(cookie.lastAccess, "a cookie access")
        }
    }

    static func searchEngine(_ engine: ImportedSearchEngine?) throws {
        guard let engine else { return }
        try FuzzRun.check(engine.search.lowercased().hasPrefix("https://") && engine.search.contains("{searchTerms}"),
                          "search engine address \(engine.search)")
    }
}

/// The Chromium Safe Storage key every fuzz profile is sealed with.
struct ImportFuzzKeys {
    static let service = "Chrome Safe Storage"
    static let password = "fuzz-safe-storage"
    static let storage = FixtureSafeStorage(passwords: [service: password])
    static let cookies = ChromiumCookieCrypto(safeStoragePassword: Data(password.utf8))
    #if !CMUX_NO_PASSWORD_IMPORT
    static let passwords = ChromiumPasswordCrypto(safeStoragePassword: SecretBytes(copying: Array(password.utf8)))
    #endif
}

/// One check per byte format: the reader takes the bytes as a damaged file would hand them over.
struct ImportFuzzCases {
    /// The clock of every read: 2026-05-08, after the fixtures' creation and before their expiry.
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Cookies

    static func safariCookies(_ data: Data) throws {
        let result: CookieReadResult
        do {
            result = try SafariBinaryCookies().parse(data, now: now)
        } catch is CookieImportError {
            return
        }
        try ImportFuzzOracle.cookies(result, now: now)
        if data == SafariCookieFixture.sample {
            let sid = result.cookies.first
            try FuzzRun.check(result.cookies.map(\.name) == ["sid", "pref"] && result.expired == 1,
                              "the Safari seed read back as \(result.cookies.map(\.name)), \(result.expired) expired")
            try FuzzRun.check(sid?.secure == true && sid?.httpOnly == true && sid?.domain == ".example.com",
                              "the Safari seed lost its flags or domain")
        }
    }

    static func chromiumCookieValue(_ data: Data) throws {
        for version in [0, 24] {
            let value: String
            do {
                value = try ImportFuzzKeys.cookies.decrypt(data, hostKey: "example.com", databaseVersion: version)
            } catch is ChromiumCookieCrypto.Failure {
                continue
            }
            if data == cookieSeed, version == 24 { try FuzzRun.check(value == "fuzz-value", "the cookie seed decrypted to another value") }
        }
        #if !CMUX_NO_PASSWORD_IMPORT
        _ = try? ImportFuzzKeys.passwords.decrypt(data)
        #endif
    }

    static let cookieSeed = (try? ImportFuzzKeys.cookies.encrypt("fuzz-value", hostKey: "example.com", databaseVersion: 24)) ?? Data()

    // MARK: Sessions

    static func chromiumSession(_ data: Data) throws {
        let read = ChromiumSessionReader().parse(data)
        let tabs = read.items
        try ImportFuzzOracle.tabs(tabs)
        if data == ChromiumSessionFixture.sample {
            try FuzzRun.check(tabs.map(\.url.absoluteString) == ["https://example.com/", "https://news.example/a?b=c"]
                                  && tabs.map(\.pinned) == [true, false] && tabs.map(\.window) == [0, 0],
                              "the Chromium session seed read back as \(tabs.map(\.url))")
            // chrome://settings is counted; the closed window's tab is not open, so it is no skip.
            try FuzzRun.check(read.skipped.notImportable == 1 && read.skipped.total == 1, "the Chromium session seed skipped \(read.skipped)")
        }
    }

    static func firefoxSession(_ data: Data) throws {
        let reader = FirefoxSessionReader()
        if let json = reader.decompress(data) {
            try FuzzRun.check(json.count <= reader.maximumSize, "a session store inflated to \(json.count) bytes")
        }
        let read = reader.parse(data)
        let tabs = read.items
        try ImportFuzzOracle.tabs(tabs)
        // Every tab of the session is imported or counted.
        if let json = reader.decompress(data), let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
            let windows = root["windows"] as? [[String: Any]] ?? []
            let count = windows.reduce(0) { $0 + (($1["tabs"] as? [Any])?.count ?? 0) }
            try FuzzRun.check(tabs.count + read.skipped.total == count, "\(count) Firefox tabs gave \(tabs.count) and \(read.skipped.total) skipped")
        }
        if data == MozLz4Fixture.sessionFile {
            try FuzzRun.check(tabs.map(\.url.absoluteString) == ["https://b.example/", "file:///tmp/x.html"]
                                  && tabs.map(\.window) == [0, 1] && tabs.map(\.pinned) == [true, false],
                              "the Firefox session seed read back as \(tabs.map(\.url))")
            // about:blank is not importable; the tab with no entries is not read.
            try FuzzRun.check(read.skipped.notImportable == 1 && read.skipped.unsupported == 1 && read.skipped.total == 2,
                              "the Firefox session seed skipped \(read.skipped)")
        }
    }

    /// A damaged session JSON, sealed as Firefox seals it.
    static func firefoxSessionJSON(_ json: Data) throws {
        try firefoxSession(MozLz4Fixture.file(json))
    }

    static func firefoxSearchEngine(_ json: Data) throws {
        let engine = FirefoxSearchEngineReader().parse(json)
        try ImportFuzzOracle.searchEngine(engine)
        if json == MozLz4Fixture.searchEngines {
            try FuzzRun.check(engine?.name == "Kagi" && engine?.keyword == "@kagi", "the Firefox search seed read back as \(String(describing: engine))")
        }
    }

    // MARK: Bookmarks

    static func chromiumBookmarks(_ data: Data) throws {
        guard let read = try? ChromiumBookmarksParser().parse(data) else { return }
        let bookmarks = read.items
        try ImportFuzzOracle.bookmarks(bookmarks)
        // The file is a tree: every entry under a root is a bookmark, a counted skip, or a folder opened.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let roots = root["roots"] as? [String: Any] {
            let entries = ["bookmark_bar", "other", "synced"].reduce(0) { $0 + chromiumEntries(roots[$1] as? [String: Any], depth: 0) }
            try FuzzRun.check(bookmarks.count + read.skipped.total == entries,
                              "\(entries) Chromium bookmark entries gave \(bookmarks.count) and \(read.skipped.total) skipped")
        }
        if data == BookmarksFixture.chromium {
            try FuzzRun.check(bookmarks.map(\.folderPath) == [["Bookmarks Bar"], ["Bookmarks Bar", "Work"], ["synced"]]
                                  && bookmarks.first?.dateAdded != nil,
                              "the Chromium bookmarks seed read back as \(bookmarks.map(\.url))")
            try FuzzRun.check(read.skipped.notImportable == 1 && read.skipped.total == 1, "the Chromium bookmarks seed skipped \(read.skipped)")
        }
    }

    /// Entries under a Chromium folder that end as a bookmark or a skip: all but the folders opened;
    /// a folder past the depth limit counts as one.
    static func chromiumEntries(_ folder: [String: Any]?, depth: Int) -> Int {
        guard let folder else { return 0 }
        return (folder["children"] as? [Any] ?? []).reduce(0) { sum, element in
            guard let child = element as? [String: Any], child["type"] as? String == "folder" else { return sum + 1 }
            return sum + (depth + 1 < ImportSkipCounts.maximumDepth ? chromiumEntries(child, depth: depth + 1) : 1)
        }
    }

    static func arcSidebar(_ data: Data) throws {
        guard let read = try? ArcSidebarReader().parse(data, profileDirectory: "Default") else { return }
        let bookmarks = read.items
        try ImportFuzzOracle.bookmarks(bookmarks)
        if data == BookmarksFixture.arc {
            try FuzzRun.check(bookmarks.map(\.folderPath) == [["Favorites"], ["Home"], ["Home", "List"]],
                              "the Arc seed read back as \(bookmarks.map(\.folderPath))")
            try FuzzRun.check(read.skipped.total == 0, "the Arc seed skipped \(read.skipped)")
        }
    }

    static func safariBookmarks(_ data: Data) throws {
        guard let read = try? SafariBookmarksParser(maximumNodes: 4096).parse(data) else { return }
        let bookmarks = read.items
        try ImportFuzzOracle.bookmarks(bookmarks)
        try FuzzRun.check(bookmarks.count <= 4096, "\(bookmarks.count) Safari bookmarks past the node cap")
        if data == BookmarksFixture.safariXML || data == BookmarksFixture.safariBinary {
            try FuzzRun.check(bookmarks.map(\.folderPath) == [["Favorites"], ["Reading List"]],
                              "the Safari bookmarks seed read back as \(bookmarks.map(\.folderPath))")
            try FuzzRun.check(read.skipped.total == 0, "the Safari bookmarks seed skipped \(read.skipped)")
        }
    }

    // MARK: Exports

    static func exportedHistory(_ data: Data) throws {
        guard let history = ExportedHistory(json: data, limit: 64) else { return }
        try ImportFuzzOracle.history(history.entries, limit: 64)
        // Rows of one URL merge into one entry, so pages and skips together are at most the rows.
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = ((root?["history"] as? [[String: Any]]) ?? (root?["Browser History"] as? [[String: Any]]))?.count ?? 0
        try FuzzRun.check(history.entries.count + history.skipped.total <= rows,
                          "\(rows) exported rows gave \(history.entries.count) pages and \(history.skipped.total) skipped")
        if data == ExportedHistoryFixture.safari {
            try FuzzRun.check(history.entries.map(\.visitCount) == [5] && history.entries.first?.title == "A2",
                              "the Safari history seed read back as \(history.entries.map(\.visitCount))")
            try FuzzRun.check(history.skipped.notImportable == 1 && history.skipped.total == 1, "the Safari history seed skipped \(history.skipped)")
        }
    }

    static func exportArchive(_ data: Data) throws {
        let archive: ExportArchive
        do {
            archive = try ExportArchive.archive(in: SecretBytes(copying: data))
        } catch is ExportArchive.Failure {
            return
        }
        try FuzzRun.check(archive.passwordCSVs.count <= 1, "\(archive.passwordCSVs.count) password files in one archive")
        for part in archive.historyJSON {
            try FuzzRun.check(part.count <= ExportArchive.maximumPart, "a history part of \(part.count) bytes")
            try exportedHistory(part)
        }
        for csv in archive.passwordCSVs {
            try FuzzRun.check(csv.count <= ExportArchive.maximumPart, "a password part of \(csv.count) bytes")
            try passwordCSV(csv)
        }
        if data == ZipFixture.sample {
            try FuzzRun.check(archive.bookmarksHTML.count == 1 && archive.historyJSON.count == 1 && archive.passwordCSVs.count == 1,
                              "the archive seed lost a part")
        }
    }

    static func passwordCSV(_ data: Data) throws {
        try passwordCSV(SecretBytes(copying: data))
    }

    /// Every data row of the file becomes a sign-in or is counted as skipped.
    static func passwordCSV(_ bytes: SecretBytes) throws {
        _ = PasswordCSVHeader.read(bytes)
        let rows = bytes.withUnsafeBytes { raw in
            // SAFETY: the view is read only inside this closure, while `bytes` lends its buffer.
            PasswordCSVReader.records(in: unsafe ByteView(raw)).dropFirst().filter { !($0.count == 1 && $0[0].isEmpty) }
        }
        for columns in [nil, PasswordCSVColumns(url: 1, username: 2, password: 3), PasswordCSVColumns(url: 0, username: 0, password: 9)] {
            let read: (logins: [ImportedLogin], skipped: LoginSkipCounts)
            do {
                read = try PasswordCSVReader().read(bytes, columns: columns)
            } catch {
                continue
            }
            try FuzzRun.check(read.logins.count + read.skipped.total == rows.count,
                              "\(rows.count) rows gave \(read.logins.count) sign-ins and \(read.skipped.total) skipped")
            for login in read.logins {
                try FuzzRun.check(login.signonRealm.hasPrefix("http") && login.signonRealm.hasSuffix("/"), "realm \(login.signonRealm)")
                try FuzzRun.check(!login.password.isEmpty && login.password.isValidUTF8, "a password that is empty or not UTF-8")
            }
            if columns == nil, bytes.matches(SecretBytes(copying: PasswordCSVFixture.sample)) {
                try FuzzRun.check(read.skipped.duplicate == 1 && read.skipped.empty == 1 && read.skipped.notWebForm >= 1,
                                  "the CSV seed skipped \(read.skipped)")
            }
        }
    }

    // MARK: Profile lists

    static func firefoxProfilesINI(_ data: Data) throws {
        let entries = FirefoxProfileList().parse(String(decoding: data, as: UTF8.self), base: URL(fileURLWithPath: "/fuzz/Firefox", isDirectory: true))
        try FuzzRun.check(entries.allSatisfy { !$0.directoryName.isEmpty }, "a Firefox profile with no path")
        if data == ProfileListFixture.ini {
            try FuzzRun.check(entries.map(\.displayName) == ["default-release", "dev"], "the profiles.ini seed read back as \(entries.map(\.displayName))")
        }
    }

    // MARK: Firefox key store DER

    #if !CMUX_NO_PASSWORD_IMPORT
    static func nssDER(_ data: Data) throws {
        let bytes = [UInt8](data)
        if let root = try? NSSDER(bytes) {
            _ = try? root.oid()
            _ = try? root.smallInteger()
            for child in (try? root.children()) ?? [] {
                _ = try? child.children()
                _ = try? child.oid()
                _ = try? child.smallInteger()
            }
        }
        let empty = SecretBytes(capacity: 0) { _ in 0 }
        let opened: SecretBytes
        do {
            opened = try FirefoxPasswordCrypto.openPBE(bytes, globalSalt: FirefoxKeyFixture.globalSalt, password: empty)
        } catch {
            return
        }
        try FuzzRun.check(opened.count <= bytes.count, "a key store item opened to more bytes than it holds")
    }
    #endif

    // MARK: libFuzzer entry

    /// One input of the byte formats: the first byte picks the reader, the rest is its file. The
    /// libFuzzer wrapper calls this; the filesystem cases are not part of it.
    static func oneInput(_ data: Data) throws {
        guard let selector = data.first else { return }
        let file = Data(data.dropFirst())
        switch selector % 14 {
        case 0: try safariCookies(file)
        case 1: try chromiumCookieValue(file)
        case 2: try chromiumSession(file)
        case 3: try firefoxSession(file)
        case 4: try firefoxSessionJSON(file)
        case 5: try firefoxSearchEngine(file)
        case 6: try chromiumBookmarks(file)
        case 7: try arcSidebar(file)
        case 8: try safariBookmarks(file)
        case 9: try exportedHistory(file)
        case 10: try exportArchive(file)
        case 11: try passwordCSV(file)
        case 13: try firefoxProfilesINI(file)
        default:
            #if !CMUX_NO_PASSWORD_IMPORT
            try nssDER(file)
            #else
            break
            #endif
        }
    }

    // MARK: Seeds and tokens

    static let jsonTokens: [Data] = [
        "{", "}", "[", "]", "\"", ":", ",", "null", "true", "false", "-1", "0", "-9223372036854775808", "9223372036854775807",
        "1e308", "-1e308", "\"\"", "\"children\"", "\"type\"", "\"url\"", "\"folder\"", "\"name\"", "\"roots\"", "\"index\"",
        "\"entries\"", "\"tabs\"", "\"windows\"", "\"childrenIds\"", "\"data\"", "\"list\"", "\"tab\"", "\"savedURL\"",
        "\"history\"", "\"visit_count\"", "\"time_usec\"", "\"engines\"", "\"_urls\"", "\"params\"", "\"metaData\"",
        "\"https://\"", "\"javascript:\"", "\"\\u0000\"", "\"\\ud800\"",
    ].map { Data($0.utf8) }

    static let binaryTokens: [Data] = [
        Data("cook".utf8), Data([0, 0, 1, 0]), Data([0xFF, 0xFF, 0xFF, 0xFF]), Data([0x7F, 0xFF, 0xFF, 0xFF]), Data([0, 0, 0, 0x80]),
        Data("SNSS".utf8), Data("mozLz40\0".utf8), Data([0x50, 0x4B, 0x03, 0x04]), Data([0x50, 0x4B, 0x01, 0x02]),
        Data([0x50, 0x4B, 0x05, 0x06]), Data([0x30, 0x82, 0xFF, 0xFF]), Data([0x30, 0x84]), Data([0x06, 0x09]), Data([0x04, 0x10]),
        Data("v10".utf8), Data("v11".utf8), Data("bplist00".utf8), Data([0xDF]), Data([0xAF, 0x11]), Data([0x5F, 0x13]),
    ]

    static let csvTokens: [Data] = [
        "\"", ",", "\r\n", "\n", "\"\"", "url", "password", "username", "httpRealm", "https://", "http://[::1]:0/", "\u{FEFF}",
    ].map { Data($0.utf8) }

    static var byteSeeds: [Data] {
        let seeds: [(UInt8, Data)] = [
            (0, SafariCookieFixture.sample), (1, cookieSeed), (2, ChromiumSessionFixture.sample),
            (3, MozLz4Fixture.sessionFile), (4, MozLz4Fixture.session), (5, MozLz4Fixture.searchEngines),
            (6, BookmarksFixture.chromium), (7, BookmarksFixture.arc), (8, BookmarksFixture.safariBinary),
            (9, ExportedHistoryFixture.takeout), (10, ZipFixture.sample), (11, PasswordCSVFixture.sample),
            (12, Data(NSSFixture.pbes2)), (12, Data(NSSFixture.tripleDES)), (12, Data(NSSFixture.login)), (13, ProfileListFixture.ini),
        ]
        return seeds.map { Data([$0.0]) + $0.1 }
    }
}
