import Foundation
import Testing
@testable import CmuxNextBrowserImport

@Suite struct CookieTests {
    let keys = FixtureSafeStorage(passwords: ["Chrome Safe Storage": CookieFixtures.password])

    /// Vectors made outside this code: Python's hashlib.pbkdf2_hmac for the
    /// key, `openssl enc -aes-128-cbc` with the 16-space IV for the value.
    @Test func chromiumCryptoMatchesIndependentVectors() throws {
        let key = ChromiumCookieCrypto.deriveKey(Data("peanuts".utf8))
        #expect(key.map { String(format: "%02x", $0) }.joined() == "d9a09d499b4e1b7461f28e67972c6dbd")
        let crypto = ChromiumCookieCrypto(safeStoragePassword: Data("peanuts".utf8))
        let cipher = Data("v10".utf8) + Data([0x6d, 0xca, 0x7d, 0x6b, 0x5c, 0xbc, 0xa1, 0x3a, 0x61, 0xd3, 0x6f, 0x60, 0x54, 0x30, 0x66, 0xa6])
        #expect(try crypto.decrypt(cipher, hostKey: "a.example", databaseVersion: 23) == "hello-cookie")
    }

    @Test(arguments: [23, 24])
    func decryptsChromiumDatabase(version: Int) throws {
        let home = try FixtureHome()
        let file = home.url.appending(path: "Cookies")
        try CookieFixtures.chromium(file, version: version, rows: [
            ("github.com", "user_session", "s3cret", ""),
            (".example.com", "pref", "dark", ""),
            ("embed.example", "chips", "x", "https://top.example"),
        ])
        let crypto = ChromiumCookieCrypto(safeStoragePassword: Data(CookieFixtures.password.utf8))
        let result = try ChromiumCookieReader().read(file, crypto: crypto)
        #expect(result.cookies.map(\.value) == ["s3cret", "dark"])
        #expect(result.partitioned == 1)
        let session = try #require(result.cookies.first)
        #expect(session.secure && session.httpOnly)
        #expect(session.sameSite == .lax)
        #expect(session.domain == "github.com")
        #expect(result.cookies[1].host == "example.com")
        #expect(session.expires != nil)
    }

    @Test func wrongKeyReportsUndecryptable() throws {
        let home = try FixtureHome()
        let file = home.url.appending(path: "Cookies")
        try CookieFixtures.chromium(file, rows: [("a.example", "n", "v", "")])
        let crypto = ChromiumCookieCrypto(safeStoragePassword: Data("not-the-key".utf8))
        #expect(throws: CookieImportError.undecryptable) { try ChromiumCookieReader().read(file, crypto: crypto) }
    }

    @Test func unknownPrefixesAreRefused() throws {
        let crypto = ChromiumCookieCrypto(safeStoragePassword: Data("k".utf8))
        for prefix in ["v11", "v20"] {
            #expect(throws: ChromiumCookieCrypto.Failure.unknownPrefix) {
                try crypto.decrypt(Data(prefix.utf8) + Data(repeating: 1, count: 32), hostKey: "a", databaseVersion: 24)
            }
        }
    }

    @Test func firefoxCookiesSkipContainers() throws {
        let home = try FixtureHome()
        let file = home.url.appending(path: "cookies.sqlite")
        try CookieFixtures.firefox(file, rows: [(".mozilla.org", "sid", "abc", ""), ("work.example", "sid", "c", "^userContextId=2")])
        let result = try FirefoxCookieReader().read(file)
        #expect(result.cookies.map(\.value) == ["abc"])
        #expect(result.cookies[0].httpOnly && result.cookies[0].sameSite == .lax)
        #expect(result.partitioned == 1)
        #expect(FirefoxCookieReader().expiry(1_900_000_000_000) == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func safariBinaryCookies() throws {
        let later = Date().addingTimeInterval(3_600)
        let data = CookieFixtures.safari([
            (".apple.com", "dslang", "/", "US-EN", 0, later),
            ("secure.example", "token", "/app", "t0k", 5, later),
            ("old.example", "gone", "/", "x", 0, Date(timeIntervalSince1970: 1_200_000_000)),
        ])
        let result = try SafariBinaryCookies().parse(data)
        #expect(result.cookies.map(\.name) == ["dslang", "token"])
        #expect(result.expired == 1)
        let token = result.cookies[1]
        #expect(token.secure && token.httpOnly && token.path == "/app" && token.value == "t0k")
        #expect(abs((token.expires ?? .distantPast).timeIntervalSince(later)) < 1)
        #expect(throws: CookieImportError.self) { try SafariBinaryCookies().parse(Data("nope".utf8)) }
    }

    @Test func cookieValuesNeverAppearInDescriptions() {
        let cookie = ImportedCookie(name: "sid", value: "TOP-SECRET-VALUE", domain: ".example.com", secure: true)
        var dumped = ""
        dump(cookie, to: &dumped)
        for text in [cookie.description, cookie.debugDescription, "\(cookie)", String(reflecting: cookie), dumped] {
            #expect(!text.contains("TOP-SECRET-VALUE"))
        }
        #expect(cookie.url?.absoluteString == "https://example.com/")
    }

    @Test func importerWritesDecryptedCookiesToTargetProfile() async throws {
        let home = try FixtureHome()
        let root = try home.chromium(.chrome, profiles: [("Default", "Personal")])
        try home.write(#"{"roots": {"bookmark_bar": {"name": "Bar", "children": []}}}"#, to: root.appending(path: "Default/Bookmarks"))
        try CookieFixtures.chromium(root.appending(path: "Default/Network/Cookies"), rows: [
            ("github.com", "user_session", "s", ""), ("github.com", "reject_me", "r", ""),
        ])
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.chrome))
        let store = RecordingCookieStore()
        let importer = BrowserImporter(provisioning: RecordingProvisioning(), cookies: CookieImporter(destination: store, keys: keys))
        let destination = RecordingDestination()
        let summary = try await importer.run(ImportPlan(items: [.init(profile: source.profiles[0], kinds: [.bookmarks, .cookies])]),
                                             into: destination) { _ in }
        let batch = try #require(summary.batches.first)
        #expect(batch.cookies == CookieImportReport(written: 1, rejected: 1))
        #expect(summary.counts.cookies == 1)
        #expect(store.received.withLock { $0[batch.source.targetProfileID]?.map(\.name) } == ["user_session"])
        // Saved batches carry counts only.
        let saved = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
        #expect(!saved.contains("user_session"))
    }

    @Test func deniedKeychainKeepsTheRestOfTheProfile() async throws {
        let home = try FixtureHome()
        let root = try home.chromium(.brave, profiles: [("Default", "Personal")])
        try home.write(#"{"roots": {"bookmark_bar": {"name": "Bar", "children": [{"type": "url", "name": "A", "url": "https://a.example/"}]}}}"#,
                       to: root.appending(path: "Default/Bookmarks"))
        try CookieFixtures.chromium(root.appending(path: "Default/Cookies"), rows: [("a.example", "n", "v", "")])
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.brave))
        let importer = BrowserImporter(cookies: CookieImporter(destination: RecordingCookieStore(), keys: keys))
        let summary = try await importer.run(ImportPlan(items: [.init(profile: source.profiles[0], kinds: [.bookmarks, .cookies])]),
                                             into: RecordingDestination()) { _ in }
        let batch = try #require(summary.batches.first)
        #expect(batch.bookmarks.count == 1)
        #expect(batch.cookieError == .keyNotFound(service: "Brave Safe Storage"))
        #expect(summary.failures.isEmpty)
    }

    @Test func torIsRefusedEvenIfAsked() throws {
        let profile = BrowserSourceProfile(browser: .tor, directoryName: "profile.default", displayName: "Tor",
                                           path: URL(fileURLWithPath: "/nonexistent"), availability: [.cookies: .available])
        #expect(throws: CookieImportError.refused) { try CookieImporter.read(profile, keys: keys, now: Date()) }
    }

    @Test func fixtureKeysOnlyWithFixtureHome() throws {
        let home = try FixtureHome()
        let file = try home.write(#"{"Chrome Safe Storage": "pw"}"#, to: home.url.appending(path: "keys.json"))
        #expect(FixtureSafeStorage(environment: [FixtureSafeStorage.environmentKey: file.path]) == nil)
        let live = SafeStorageKeys(environment: [ImportEnvironment.fixtureHomeKey: home.url.path, FixtureSafeStorage.environmentKey: file.path]).live()
        #expect(try live.password(service: "Chrome Safe Storage").matches(SecretBytes(copying: Array("pw".utf8))))
        // A fixture home without a key file never falls back to the real Keychain.
        let empty = SafeStorageKeys(environment: [ImportEnvironment.fixtureHomeKey: home.url.path]).live()
        #expect(throws: CookieImportError.keyNotFound(service: "Chrome Safe Storage")) { try empty.password(service: "Chrome Safe Storage") }
    }
}
