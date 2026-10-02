import Foundation
import Synchronization
import Testing
@testable import CmuxNextBrowserImport

/// Synthetic Login Data only: the Safe Storage password is random bytes made
/// here and every saved password is a made-up marker. No real Keychain item
/// or browser store is read.
@Suite struct PasswordImportTests {
    /// A Safe Storage password generated for this test run.
    let storagePassword = SecretBytes(copying: (0..<24).map { _ in UInt8.random(in: 0...255) })
    var crypto: ChromiumPasswordCrypto { ChromiumPasswordCrypto(safeStoragePassword: storagePassword) }
    /// Every synthetic password contains this, so a scan can look for it.
    static let marker = "cmux-test-secret-\(UUID().uuidString)"

    func sealed(_ plain: String) throws -> String {
        let data = try crypto.encrypt(SecretBytes(copying: Array(plain.utf8)))
        return "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    static let schema = """
        CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
        password_element VARCHAR, password_value BLOB, signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL,
        blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL, federation_url VARCHAR)
        """

    func row(_ realm: String, _ user: String, _ value: String, created: Int64 = 13_300_000_000_000_000, never: Int = 0, scheme: Int = 0,
             federation: String = "") -> String {
        "INSERT INTO logins VALUES ('\(realm)login', '', 'u', '\(user)', 'p', \(value), '\(realm)', \(created), \(never), \(scheme), '\(federation)')"
    }

    func plain(_ secret: SecretBytes) -> String { secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }

    func edgeProfile(_ home: FixtureHome) throws -> URL {
        let profile = home.directory(.edge).appending(path: "Default", directoryHint: .isDirectory)
        try FixtureHome.sqlite(profile.appending(path: "Login Data"), [
            Self.schema,
            row("https://github.com/", "octo", try sealed("\(Self.marker)-github-old"), created: 13_300_000_000_000_000),
            row("https://example.org/", "never", "X''", never: 1),
            row("https://accounts.example/", "fed", try sealed("x"), federation: "https://idp.example"),
            row("https://intranet.example/", "basic", try sealed("x"), scheme: 1),
            row("android://hash@com.example/", "app", try sealed("x")),
            row("https://empty.example/", "nobody", "X''"),
            // "v10" and a cut-off block: no key opens it.
            row("https://other.example/", "stranger", "X'7631300102030405'"),
            row("https://windows.example/", "v20", "X'763230AABBCC'"),
        ])
        // The account store has a newer password for the same sign-in and one more site.
        try FixtureHome.sqlite(profile.appending(path: "Login Data For Account"), [
            Self.schema,
            row("https://github.com/", "octo", try sealed("\(Self.marker)-github-new"), created: 13_400_000_000_000_000),
            row("https://news.example/", "reader", try sealed("\(Self.marker)-news")),
        ])
        return profile
    }

    @Test func readsWebFormPasswordsAndSaysWhatItSkipped() throws {
        let home = try FixtureHome()
        let profile = try edgeProfile(home)
        let (logins, skipped) = try ChromiumLoginDataReader().read(profile: profile, crypto: crypto)
        #expect(logins.map(\.signonRealm) == ["https://github.com/", "https://news.example/"])
        #expect(logins.map { plain($0.password) } == ["\(Self.marker)-github-new", "\(Self.marker)-news"], "the newest of a duplicate wins")
        #expect(logins[0].username == "octo")
        var expected = LoginSkipCounts()
        expected.neverSaved = 1
        expected.notWebForm = 3
        expected.empty = 1
        expected.undecryptable = 2
        expected.duplicate = 1
        #expect(skipped == expected)
    }

    @Test func valuesNeverPrintOrReflect() throws {
        let home = try FixtureHome()
        let (logins, _) = try ChromiumLoginDataReader().read(profile: try edgeProfile(home), crypto: crypto)
        let login = try #require(logins.first)
        for text in ["\(login)", String(reflecting: login), "\(login.password)", String(reflecting: login.password), "\(logins)"] {
            #expect(!text.contains(Self.marker))
            #expect(!text.contains("octo"), "the username is not printed either")
        }
        #expect(Mirror(reflecting: login).children.isEmpty && Mirror(reflecting: login.password).children.isEmpty)
    }

    /// A cut-off block, or bytes a wrong key leaves with valid padding, are
    /// undecryptable, never a password made of garbage.
    @Test func onlyWholeBlocksOfUTF8Decrypt() throws {
        #expect(throws: ChromiumPasswordCrypto.Failure.undecryptable) { try crypto.decrypt(Data("v10".utf8) + Data([1, 2, 3, 4, 5])) }
        #expect(throws: ChromiumPasswordCrypto.Failure.undecryptable) { try crypto.decrypt(Data("v10".utf8)) }
        let notText = try crypto.encrypt(SecretBytes(copying: [0xFF, 0xFE, 0x00]))
        #expect(throws: ChromiumPasswordCrypto.Failure.undecryptable) { try crypto.decrypt(notText) }
        let text = try crypto.encrypt(SecretBytes(copying: Array("pässwörd".utf8)))
        #expect(try crypto.decrypt(text).matches(SecretBytes(copying: Array("pässwörd".utf8))))
    }

    @Test func zeroEmptiesTheBytesAtOnce() {
        let secret = SecretBytes(copying: Array("hunter2".utf8))
        secret.zero()
        #expect(secret.isEmpty)
        #expect(secret.unsafeBytesWhileAlive.isEmpty)
        secret.zero()
    }

    @Test func aFailedFillFreesOnce() {
        struct Stop: Error {}
        #expect(throws: Stop.self) { _ = try SecretBytes(capacity: 32) { _ in throw Stop() } }
        let one = SecretBytes(capacity: 3) { buffer in
            #expect(buffer.count == 3, "fill sees the capacity asked for, not the whole page")
            buffer.copyBytes(from: [1, 2, 3])
            return 3
        }
        #expect(one.count == 3)
    }

    @Test func secretBytesCompareAndCopy() {
        let one = SecretBytes(copying: Array("same".utf8))
        #expect(one.matches(SecretBytes(copying: Array("same".utf8))))
        #expect(!one.matches(SecretBytes(copying: Array("diff".utf8))))
        #expect(!one.matches(SecretBytes(copying: Array("longer".utf8))))
        #expect(SecretBytes(copying: [UInt8]()).isEmpty)
    }

    @Test func importsIntoTheDestinationAndReportsCountsOnly() async throws {
        let home = try FixtureHome()
        let profile = try edgeProfile(home)
        let store = RecordingPasswordStore(reply: PasswordStoreReply(added: 1, duplicate: 1))
        let source = BrowserSourceProfile(browser: .edge, directoryName: "Default", displayName: "Work", path: profile,
                                          availability: [.passwords: .available])
        let keys = FixtureKeys(service: "Microsoft Edge Safe Storage", password: storagePassword)
        let report = try await PasswordImporter(keys: keys, destination: store).run(source, intoProfile: "profile-uuid")
        #expect(store.batches == [["https://github.com/", "https://news.example/"]])
        #expect(store.profiles == ["profile-uuid"])
        #expect(report.read == 10 && report.imported == 1 && report.notImported == 9)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains(Self.marker) && !encoded.contains("github"))
    }

    @Test func plaintextNeverReachesDisk() async throws {
        let home = try FixtureHome()
        let profile = try edgeProfile(home)
        let started = Date()
        let source = BrowserSourceProfile(browser: .edge, directoryName: "Default", displayName: "Work", path: profile,
                                          availability: [.passwords: .available])
        _ = try await PasswordImporter(keys: FixtureKeys(service: "Microsoft Edge Safe Storage", password: storagePassword),
                                       destination: RecordingPasswordStore()).run(source, intoProfile: "p")
        // Every file written since the import began, in the temp folder and the fixture home.
        let marker = Data(Self.marker.utf8)
        for root in [FileManager.default.temporaryDirectory, home.url] {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
            while let file = files?.nextObject() as? URL { // wakeup-allow: bounded by the folder listing
                let values = try? file.resourceValues(forKeys: Set(keys))
                let recent = (values?.contentModificationDate ?? .distantPast) >= started
                // A folder untouched since the start holds nothing new (adding or removing an entry updates it).
                if values?.isDirectory == true, !recent { files?.skipDescendants() }
                guard values?.isRegularFile == true, recent,
                      let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                #expect(data.range(of: marker) == nil, "plaintext found in \(file.lastPathComponent)")
            }
        }
    }

    @Test func theImportRunCarriesPasswordCountsOnly() async throws {
        let home = try FixtureHome()
        let profile = try edgeProfile(home)
        let source = BrowserSourceProfile(browser: .edge, directoryName: "Default", displayName: "Work", path: profile,
                                          availability: [.passwords: .available])
        let keys = FixtureKeys(service: "Microsoft Edge Safe Storage", password: storagePassword)
        let store = RecordingPasswordStore(reply: PasswordStoreReply(added: 2))
        let importer = BrowserImporter(passwords: PasswordImporter(keys: keys, destination: store))
        let summary = try await importer.run(ImportPlan(items: [ImportPlan.Item(profile: source, kinds: [.passwords])]),
                                             into: RecordingDestination()) { _ in }
        #expect(summary.counts == ImportCounts(passwords: 2))
        #expect(summary.batches.first?.passwords?.notImported == 8)
        let saved = String(decoding: try JSONEncoder().encode(summary.batches), as: UTF8.self)
        #expect(!saved.contains(Self.marker) && !saved.contains("octo"), "the saved summary has counts only")

        // A denied Keychain prompt fails the passwords, not the profile.
        let denied = BrowserImporter(passwords: PasswordImporter(keys: FixtureKeys(service: "Other", password: storagePassword), destination: store))
        let refused = try await denied.run(ImportPlan(items: [ImportPlan.Item(profile: source, kinds: [.passwords])]),
                                           into: RecordingDestination()) { _ in }
        #expect(refused.failures.isEmpty)
        #expect(refused.batches.first?.passwordError == .key(.keyNotFound(service: "Microsoft Edge Safe Storage")))
    }

    @Test func oneKeychainPromptPerBrowserPerRun() throws {
        let counting = CountingKeys(password: storagePassword)
        let keys = OneReadSafeStorage(counting)
        #expect(try keys.password(service: "Microsoft Edge Safe Storage") === keys.password(service: "Microsoft Edge Safe Storage"), "one shared copy")
        #expect(throws: CookieImportError.keychainDenied(service: "Google Chrome Safe Storage")) { try keys.password(service: "Google Chrome Safe Storage") }
        #expect(throws: CookieImportError.keychainDenied(service: "Google Chrome Safe Storage")) { try keys.password(service: "Google Chrome Safe Storage") }
        #expect(counting.reads.withLock { $0 } == ["Microsoft Edge Safe Storage", "Google Chrome Safe Storage"], "a Deny is not asked again")
    }

    @Test func refusesWhatItCannotDoSafely() async throws {
        let home = try FixtureHome()
        let profile = try edgeProfile(home)
        let keys = FixtureKeys(service: "Microsoft Edge Safe Storage", password: storagePassword)
        let edge = BrowserSourceProfile(browser: .edge, directoryName: "Default", displayName: "Work", path: profile, availability: [:])
        let firefox = BrowserSourceProfile(browser: .firefox, directoryName: "x", displayName: "x", path: profile, availability: [:])
        await #expect(throws: PasswordImporter.Failure.unsupportedBrowser) {
            try await PasswordImporter(keys: keys, destination: RecordingPasswordStore()).run(firefox, intoProfile: "p")
        }
        await #expect(throws: PasswordImporter.Failure.storeUnavailable) {
            try await PasswordImporter(keys: keys, destination: RecordingPasswordStore(available: false)).run(edge, intoProfile: "p")
        }
        let denied = PasswordImporter(keys: FixtureKeys(service: "Other", password: storagePassword), destination: RecordingPasswordStore())
        await #expect(throws: PasswordImporter.Failure.key(.keyNotFound(service: "Microsoft Edge Safe Storage"))) {
            try await denied.run(edge, intoProfile: "p")
        }
    }
}

/// Hands out one Safe Storage password for one service.
struct FixtureKeys: SafeStorageKeyProviding {
    let service: String
    let password: SecretBytes

    func password(service: String) throws(CookieImportError) -> SecretBytes {
        guard service == self.service else { throw .keyNotFound(service: service) }
        return password
    }
}

/// Edge's key for Edge; a Deny for anything else. Counts the reads (each one is a macOS prompt).
final class CountingKeys: SafeStorageKeyProviding {
    let password: SecretBytes
    let reads = Mutex<[String]>([])

    init(password: SecretBytes) { self.password = password }

    func password(service: String) throws(CookieImportError) -> SecretBytes {
        reads.withLock { $0.append(service) }
        guard service == "Microsoft Edge Safe Storage" else { throw .keychainDenied(service: service) }
        return SecretBytes(copying: password.withUnsafeBytes { Array($0) })
    }
}

/// Records which sites reached the store (never the values) and replies with fixed counts.
final class RecordingPasswordStore: PasswordDestination, @unchecked Sendable {
    let isAvailable: Bool
    let reply: PasswordStoreReply
    private(set) var batches: [[String]] = []
    private(set) var profiles: [String] = []

    init(available: Bool = true, reply: PasswordStoreReply = PasswordStoreReply()) {
        isAvailable = available
        self.reply = reply
    }

    func add(_ logins: [ImportedLogin], toProfile profileID: String) async throws -> PasswordStoreReply {
        batches.append(logins.map(\.signonRealm))
        profiles.append(profileID)
        return reply
    }
}
