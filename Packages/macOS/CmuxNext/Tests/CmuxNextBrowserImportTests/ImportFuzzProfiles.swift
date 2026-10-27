import CmuxFuzzSupport
@testable import CmuxNextBrowserImport
import Foundation

/// Scratch folders and in-place damage of the files a profile holds.
struct ImportFuzzFiles {
    /// A new empty folder for one iteration, removed after `body`.
    static func scratch<R>(_ name: String, _ body: (URL) throws -> R) throws -> R {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "cmux-import-fuzz-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    /// What a damaged disk or a browser killed mid-write leaves: bytes overwritten in place (a torn
    /// page), a cut-off file, an empty one, or one where the edits move everything after them.
    static func damage(_ file: URL, _ rng: inout FuzzRNG) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        switch rng.below(8) {
        case 0:
            bytes.removeSubrange(rng.below(bytes.count + 1)...)
        case 1:
            bytes = []
        case 2:
            bytes = [UInt8](FuzzMutator(dictionary: ImportFuzzCases.binaryTokens, maximumCount: bytes.count * 2 + 64)
                .mutate(Data(bytes), using: &rng))
        default:
            let inPlace: [FuzzMutator.Edit] = [.changeByte, .flipBit, .addToByte, .swapBytes, .overwriteToken]
            let mutator = FuzzMutator(dictionary: ImportFuzzCases.binaryTokens)
            for _ in 0..<(1 + rng.below(8)) {
                guard !bytes.isEmpty, let edit = rng.element(of: inPlace) else { break }
                let count = bytes.count
                mutator.apply(edit, to: &bytes, using: &rng)
                if bytes.count > count { bytes.removeSubrange(count...) }
            }
        }
        try Data(bytes).write(to: file)
    }
}

/// Destinations that take everything, so the counts show what the readers handed on.
struct ImportFuzzCookieSink: CookieDestination {
    func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
        CookieWriteResult(written: cookies.count, rejected: 0)
    }
}

struct ImportFuzzPasswordSink: PasswordDestination {
    var isAvailable: Bool { true }
    func add(_ logins: [ImportedLogin], toProfile profileID: String) async throws -> PasswordStoreReply {
        PasswordStoreReply(added: logins.count)
    }
}

struct ImportFuzzDiscard: ImportDestination {
    func commit(_ batch: ImportBatch) async throws {}
}

/// A home folder with a Chrome, a Firefox and a Safari profile, each holding every file the import
/// reads, valid; then a random set of those files damaged. The importer must report each profile as
/// imported or failed, never trap, and import an undamaged profile in full.
struct ImportFuzzHome: Sendable {
    struct Profile: Sendable {
        var source: BrowserSourceProfile
        var kinds: Set<ImportDataKind>
        var files: [URL]
        var damaged: Set<URL> = []
        /// What an undamaged import of this profile gives.
        var expected: ImportCounts
        /// The entries an undamaged import leaves out and counts: bookmarks, history pages, open tabs.
        var skipped: (bookmarks: Int, history: Int, openTabs: Int) = (0, 0, 0)
    }

    let home: URL
    var profiles: [Profile] = []

    static let all: [ImportDataKind: DataAvailability] = Dictionary(uniqueKeysWithValues: ImportDataKind.allCases.map { ($0, DataAvailability.available) })

    init(_ home: URL) throws {
        self.home = home
        profiles = [try chrome(), try firefox(), try safari()]
    }

    private func folder(_ path: String) throws -> URL {
        let url = home.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func chrome() throws -> Profile {
        let path = try folder("Library/Application Support/Google/Chrome/Default")
        _ = try folder("Library/Application Support/Google/Chrome/Default/Network")
        _ = try folder("Library/Application Support/Google/Chrome/Default/Sessions")
        let bookmarks = path.appending(path: "Bookmarks")
        try BookmarksFixture.chromium.write(to: bookmarks)
        let history = path.appending(path: "History")
        let visit = Int64((ImportFuzzCases.now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        try SQLiteFixture.create(history, """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url, title, visit_count, typed_count, last_visit_time, hidden);
            INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES
              ('https://a.example/', 'A', 3, 0, \(visit), 0), ('https://b.example/', 'B', 1, 1, \(visit - 1), 0),
              ('chrome://history', 'H', 1, 0, \(visit), 0);
            """)
        let session = path.appending(path: "Sessions/Session_13300000000000000")
        try ChromiumSessionFixture.sample.write(to: session)
        let cookies = path.appending(path: "Network/Cookies")
        let sealed = { (value: String, host: String) in
            SQLiteFixture.blob((try? ImportFuzzKeys.cookies.encrypt(value, hostKey: host, databaseVersion: 24)) ?? Data())
        }
        let expires = visit + 86_400_000_000 * 365 * 20
        try SQLiteFixture.create(cookies, """
            CREATE TABLE meta (key, value); INSERT INTO meta VALUES ('version', '24');
            CREATE TABLE cookies (host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite,
              top_frame_site_key, has_expires, creation_utc, last_access_utc);
            INSERT INTO cookies VALUES ('.example.com', 'sid', '', \(sealed("one", ".example.com")), '/', \(expires), 1, 1, 1, '', 1, \(visit), \(visit)),
              ('a.example', 'pref', '', \(sealed("two", "a.example")), '/', 0, 0, 0, -1, '', 0, \(visit), \(visit));
            """)
        var files = [bookmarks, history, session, cookies]
        var kinds: Set<ImportDataKind> = [.bookmarks, .history, .openTabs, .cookies]
        var passwords = 0
        #if !CMUX_NO_PASSWORD_IMPORT
        let logins = path.appending(path: "Login Data")
        let password = { (text: String) in
            SQLiteFixture.blob((try? ImportFuzzKeys.passwords.encrypt(SecretBytes(copying: Array(text.utf8)))) ?? Data())
        }
        try SQLiteFixture.create(logins, """
            CREATE TABLE logins (origin_url, signon_realm, username_value, password_value, date_created, blacklisted_by_user, scheme, federation_url);
            INSERT INTO logins VALUES ('https://example.com/login', 'https://example.com/', 'ann', \(password("pw1")), \(visit), 0, 0, ''),
              ('https://a.example/', 'https://a.example/', 'bob', \(password("pw2")), \(visit), 0, 0, '');
            """)
        files.append(logins)
        kinds.insert(.passwords)
        passwords = 2
        #endif
        let source = BrowserSourceProfile(browser: .chrome, directoryName: "Default", displayName: "Person 1", path: path, availability: Self.all)
        return Profile(source: source, kinds: kinds, files: files,
                       expected: ImportCounts(bookmarks: 3, history: 2, openTabs: 2, cookies: 2, passwords: passwords),
                       // chrome://flags, chrome://history and chrome://settings.
                       skipped: (bookmarks: 1, history: 1, openTabs: 1))
    }

    private func firefox() throws -> Profile {
        let path = try folder("Library/Application Support/Firefox/Profiles/fuzz.default-release")
        let places = path.appending(path: "places.sqlite")
        let visit = Int64(ImportFuzzCases.now.timeIntervalSince1970 * 1_000_000)
        try SQLiteFixture.create(places, """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url, title, visit_count, last_visit_date, hidden);
            INSERT INTO moz_places VALUES (1, 'https://mozilla.org/', 'Mozilla', 4, \(visit), 0), (2, 'https://b.example/', NULL, 1, \(visit - 5), 0);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type, fk, parent, position, title, dateAdded, guid);
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 0, 'root________'), (2, 2, NULL, 1, 0, 'toolbar', 0, 'toolbar_____'),
              (3, 1, 1, 2, 0, 'Mozilla', \(visit), 'aaaaaaaaaaaa'), (4, 2, NULL, 2, 1, 'Work', 0, 'bbbbbbbbbbbb'),
              (5, 1, 2, 4, 0, NULL, \(visit), 'cccccccccccc'), (6, 2, NULL, 1, 1, 'tags', 0, 'tags________'),
              (7, 1, 1, 6, 0, 'tagged', 0, 'dddddddddddd');
            """)
        let session = path.appending(path: "sessionstore.jsonlz4")
        try MozLz4Fixture.file(MozLz4Fixture.session).write(to: session)
        let cookies = path.appending(path: "cookies.sqlite")
        try SQLiteFixture.create(cookies, """
            CREATE TABLE moz_cookies (host, name, value, path, expiry, isSecure, isHttpOnly, sameSite, originAttributes, creationTime, lastAccessed);
            INSERT INTO moz_cookies VALUES ('.mozilla.org', 'a', '1', '/', 4102444800, 1, 0, 1, '', \(visit), \(visit)),
              ('b.example', 'b', '2', '/', 4102444800000, 0, 1, 256, '', \(visit), \(visit)),
              ('c.example', 'c', '3', '/', 4102444800, 0, 0, 0, '^userContextId=2', \(visit), \(visit));
            """)
        var files = [places, session, cookies]
        var kinds: Set<ImportDataKind> = [.bookmarks, .history, .openTabs, .cookies]
        var passwords = 0
        #if !CMUX_NO_PASSWORD_IMPORT
        let key4 = path.appending(path: "key4.db")
        try FirefoxKeyFixture.key4(key4)
        let logins = path.appending(path: "logins.json")
        let entries: [[String: Any]] = [
            ["hostname": "https://example.com", "encryptedUsername": try FirefoxKeyFixture.seal(Array("ann".utf8)),
             "encryptedPassword": try FirefoxKeyFixture.seal(Array("pw1".utf8)), "timeCreated": 1.7e12],
            ["hostname": "https://mozilla.org", "encryptedUsername": try FirefoxKeyFixture.seal(Array("bob".utf8)),
             "encryptedPassword": try FirefoxKeyFixture.seal(Array("pw2".utf8))],
        ]
        try JSONSerialization.data(withJSONObject: ["logins": entries]).write(to: logins)
        files += [key4, logins]
        kinds.insert(.passwords)
        passwords = 2
        #endif
        let source = BrowserSourceProfile(browser: .firefox, directoryName: "Profiles/fuzz.default-release", displayName: "default-release",
                                          path: path, availability: Self.all)
        return Profile(source: source, kinds: kinds, files: files,
                       expected: ImportCounts(bookmarks: 2, history: 2, openTabs: 2, cookies: 2, passwords: passwords),
                       // about:blank and a tab with no entries; the tag assignment is no bookmark, so no skip.
                       skipped: (bookmarks: 0, history: 0, openTabs: 2))
    }

    private func safari() throws -> Profile {
        let path = try folder("Library/Safari")
        let bookmarks = path.appending(path: "Bookmarks.plist")
        try BookmarksFixture.safariBinary.write(to: bookmarks)
        let history = path.appending(path: "History.db")
        let visit = ImportFuzzCases.now.timeIntervalSinceReferenceDate
        try SQLiteFixture.create(history, """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url, visit_count);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item, visit_time, title);
            INSERT INTO history_items VALUES (1, 'https://apple.com/', 2), (2, 'https://webkit.org/', 1);
            INSERT INTO history_visits (history_item, visit_time, title) VALUES (1, \(visit), 'Apple'), (1, \(visit - 60), 'Old'),
              (2, \(visit - 30), 'WebKit');
            """)
        let container = try folder("Library/Containers/com.apple.Safari/Data/Library/Cookies")
        let cookies = container.appending(path: "Cookies.binarycookies")
        try SafariCookieFixture.sample.write(to: cookies)
        let source = BrowserSourceProfile(browser: .safari, directoryName: "", displayName: "Safari", path: path, availability: Self.all)
        return Profile(source: source, kinds: [.bookmarks, .history, .cookies], files: [bookmarks, history, cookies],
                       expected: ImportCounts(bookmarks: 2, history: 2, cookies: 2))
    }

    /// Damages a random set of files (none, some, or all of a profile's).
    mutating func damage(_ rng: inout FuzzRNG) throws {
        for index in profiles.indices {
            let chance = rng.element(of: [0, 2, 4, 1]) ?? 0
            for file in profiles[index].files where chance > 0 && rng.oneIn(chance) {
                if rng.oneIn(10) {
                    try FileManager.default.removeItem(at: file)
                } else {
                    try ImportFuzzFiles.damage(file, &rng)
                }
                profiles[index].damaged.insert(file)
            }
        }
    }

    /// Runs the importer over every profile and checks what it reported for each.
    func check() async throws {
        let importer = BrowserImporter(cookies: CookieImporter(destination: ImportFuzzCookieSink(), keys: ImportFuzzKeys.storage),
                                       passwords: PasswordImporter(keys: ImportFuzzKeys.storage, destination: ImportFuzzPasswordSink()))
        let plan = ImportPlan(items: profiles.map { ImportPlan.Item(profile: $0.source, kinds: $0.kinds) })
        try FuzzRun.check(plan.items.count == profiles.count, "the plan dropped a profile")
        let summary = try await importer.run(plan, into: ImportFuzzDiscard()) { _ in }
        for profile in profiles {
            let id = profile.source.id
            let batches = summary.batches.filter { $0.source.sourceKey == id }
            let failed = summary.failures[id] != nil
            try FuzzRun.check(batches.count + (failed ? 1 : 0) == 1, "\(id) is reported \(batches.count) times and failed: \(failed)")
            try FuzzRun.check(!failed || !profile.damaged.isEmpty, "undamaged \(id) failed: \(summary.failures[id] ?? "")")
            guard let batch = batches.first else { continue }
            try ImportFuzzOracle.bookmarks(batch.bookmarks)
            try ImportFuzzOracle.history(batch.history, limit: ImportPlan.defaultHistoryLimit)
            try ImportFuzzOracle.tabs(batch.openTabs)
            // Cookies and passwords fail on their own: each is a report or a reason, never neither.
            if profile.kinds.contains(.cookies) {
                try FuzzRun.check((batch.cookies == nil) != (batch.cookieError == nil), "\(id) cookies have no report and no reason")
            }
            if profile.kinds.contains(.passwords) {
                try FuzzRun.check((batch.passwords == nil) != (batch.passwordError == nil), "\(id) passwords have no report and no reason")
            }
            if profile.damaged.isEmpty {
                try FuzzRun.check(batch.counts == profile.expected && batch.cookieError == nil && batch.passwordError == nil,
                                  "undamaged \(id) imported \(batch.counts), expected \(profile.expected); cookies \(String(describing: batch.cookieError)), passwords \(String(describing: batch.passwordError))")
                // Every entry of the profile's files is imported or counted: the counts above plus these are all of them.
                let skipped = (bookmarks: batch.skippedBookmarks.total, history: batch.skippedHistory.total, openTabs: batch.skippedOpenTabs.total)
                try FuzzRun.check(skipped == profile.skipped, "undamaged \(id) skipped \(skipped), expected \(profile.skipped)")
            }
        }
    }
}
