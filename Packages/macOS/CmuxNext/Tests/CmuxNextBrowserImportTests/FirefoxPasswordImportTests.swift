import CommonCrypto
import Foundation
import Synchronization
import Testing
@testable import CmuxNextBrowserImport

/// Synthetic Firefox profiles only: `key4.db` and `logins.json` are built
/// here with a global salt, master key and primary password generated for the
/// run, and every saved password is a made-up marker. No real browser store,
/// Keychain item or primary password is read.
@Suite struct FirefoxPasswordImportTests {
    static let marker = "cmux-ff-secret-\(UUID().uuidString)"

    @Test func readsAModernProfileWithoutAPrimaryPassword() throws {
        let fixture = try FirefoxFixture(primaryPassword: "", keyScheme: .pbes2)
        try fixture.writeLogins([
            .init(hostname: "https://github.com", username: "octo", password: "\(Self.marker)-github", cipher: .aes),
            .init(hostname: "https://legacy.example:8443", username: "old", password: "\(Self.marker)-legacy", cipher: .tripleDES),
            .init(hostname: "https://intranet.example", username: "basic", password: "x", httpRealm: "Intranet"),
            .init(hostname: "chrome://FirefoxAccounts", username: "fxa", password: "x"),
            .init(hostname: "https://broken.example", username: "b", password: "x", corrupt: true),
            // The same sign-in twice: the newer one is kept.
            .init(hostname: "https://github.com", username: "octo", password: "\(Self.marker)-github-new", created: 1_800_000_000_000),
        ])
        let read = try FirefoxLoginReader().read(profile: fixture.profile, primaryPassword: nil)
        #expect(read.logins.map(\.signonRealm) == ["https://github.com/", "https://legacy.example:8443/"])
        #expect(read.logins.map(\.username) == ["octo", "old"])
        #expect(read.logins.map { plain($0.password) } == ["\(Self.marker)-github-new", "\(Self.marker)-legacy"])
        #expect(read.skipped.notWebForm == 2 && read.skipped.undecryptable == 1 && read.skipped.duplicate == 1)
        #expect(!String(describing: read.logins).contains(Self.marker))
    }

    @Test func aPrimaryPasswordIsNeededAndChecked() throws {
        let fixture = try FirefoxFixture(primaryPassword: "fixture-\(UUID().uuidString)", keyScheme: .pbes2)
        try fixture.writeLogins([.init(hostname: "https://news.example", username: "reader", password: "\(Self.marker)-news")])
        #expect(throws: FirefoxPasswordCrypto.Failure.primaryPasswordNeeded) {
            try FirefoxLoginReader().read(profile: fixture.profile, primaryPassword: nil)
        }
        #expect(throws: FirefoxPasswordCrypto.Failure.wrongPrimaryPassword) {
            try FirefoxLoginReader().read(profile: fixture.profile, primaryPassword: SecretBytes(copying: Array("wrong".utf8)))
        }
        let read = try FirefoxLoginReader().read(profile: fixture.profile, primaryPassword: SecretBytes(copying: Array(fixture.primaryPassword.utf8)))
        #expect(read.logins.map { plain($0.password) } == ["\(Self.marker)-news"])
    }

    @Test func readsAnOlderTripleDESKeyStore() throws {
        let fixture = try FirefoxFixture(primaryPassword: "", keyScheme: .sha1TripleDES)
        try fixture.writeLogins([.init(hostname: "http://localhost:8000", username: "dev", password: "\(Self.marker)-local", cipher: .tripleDES)])
        let read = try FirefoxLoginReader().read(profile: fixture.profile, primaryPassword: nil)
        #expect(read.logins.map(\.signonRealm) == ["http://localhost:8000/"])
        #expect(read.logins.map { plain($0.password) } == ["\(Self.marker)-local"])
    }

    @Test func importsThroughTheImporterAndAsksForThePrimaryPasswordOnce() async throws {
        let fixture = try FirefoxFixture(primaryPassword: "fixture-\(UUID().uuidString)", keyScheme: .pbes2)
        try fixture.writeLogins([.init(hostname: "https://news.example", username: "reader", password: "\(Self.marker)-news")])
        let source = BrowserSourceProfile(browser: .firefox, directoryName: "abc.default", displayName: "default", path: fixture.profile,
                                          availability: [.passwords: .available])
        let asked = AskCount()
        let store = RecordingPasswordStore(reply: PasswordStoreReply(added: 1))
        let primary = fixture.primaryPassword
        let importer = PasswordImporter(keys: NoKeys(), destination: store) { _ in
            asked.count.withLock { $0 += 1 }
            return SecretBytes(copying: Array(primary.utf8))
        }
        let report = try await importer.run(source, intoProfile: "profile-uuid")
        #expect(report.imported == 1 && store.batches == [["https://news.example/"]])
        #expect(asked.count.withLock { $0 } == 1)

        let cancelled = PasswordImporter(keys: NoKeys(), destination: RecordingPasswordStore()) { _ in nil }
        await #expect(throws: PasswordImporter.Failure.primaryPasswordNeeded) { try await cancelled.run(source, intoProfile: "p") }
        let wrong = PasswordImporter(keys: NoKeys(), destination: RecordingPasswordStore()) { _ in SecretBytes(copying: Array("no".utf8)) }
        await #expect(throws: PasswordImporter.Failure.wrongPrimaryPassword) { try await wrong.run(source, intoProfile: "p") }
    }

    @Test func aProfileWithoutAPrimaryPasswordNeverAsks() async throws {
        let fixture = try FirefoxFixture(primaryPassword: "", keyScheme: .pbes2)
        try fixture.writeLogins([.init(hostname: "https://news.example", username: "reader", password: "\(Self.marker)-news")])
        let source = BrowserSourceProfile(browser: .zen, directoryName: "x", displayName: "x", path: fixture.profile, availability: [:])
        let importer = PasswordImporter(keys: NoKeys(), destination: RecordingPasswordStore(reply: PasswordStoreReply(added: 1))) { _ in
            Issue.record("asked for a primary password the profile does not have")
            return nil
        }
        #expect(try await importer.run(source, intoProfile: "p").imported == 1)
    }

    @Test func plaintextNeverReachesDisk() async throws {
        let fixture = try FirefoxFixture(primaryPassword: "", keyScheme: .pbes2)
        try fixture.writeLogins([.init(hostname: "https://news.example", username: "reader", password: "\(Self.marker)-news")])
        let started = Date()
        let source = BrowserSourceProfile(browser: .firefox, directoryName: "x", displayName: "x", path: fixture.profile, availability: [:])
        _ = try await PasswordImporter(keys: NoKeys(), destination: RecordingPasswordStore()).run(source, intoProfile: "p")
        let marker = Data(Self.marker.utf8)
        for root in [FileManager.default.temporaryDirectory, fixture.home.url] {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
            while let file = files?.nextObject() as? URL { // wakeup-allow: bounded by the folder listing
                let values = try? file.resourceValues(forKeys: Set(keys))
                let recent = (values?.contentModificationDate ?? .distantPast) >= started
                if values?.isDirectory == true, !recent { files?.skipDescendants() }
                guard values?.isRegularFile == true, recent, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                #expect(data.range(of: marker) == nil, "plaintext found in \(file.lastPathComponent)")
            }
        }
    }

    @Test func detectionOffersFirefoxPasswordsOnlyWithBothFiles() throws {
        let fixture = try FirefoxFixture(primaryPassword: "", keyScheme: .pbes2)
        try fixture.writeLogins([])
        #expect(BrowserSourceDetector.firefoxAvailability(fixture.profile, browser: .firefox)[.passwords] == .available)
        #expect(BrowserSourceDetector.firefoxAvailability(fixture.profile, browser: .tor)[.passwords] == .unsupported(.refusedForPrivacy))
        try FileManager.default.removeItem(at: fixture.profile.appending(path: "key4.db"))
        #expect(BrowserSourceDetector.firefoxAvailability(fixture.profile, browser: .firefox)[.passwords] == .unsupported(.exportFromSource))
    }

    func plain(_ secret: SecretBytes) -> String { secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }
}

/// How many times the importer asked for a primary password.
final class AskCount: Sendable {
    let count = Mutex(0)
}

/// Firefox reads no Keychain item; any request is a test failure.
struct NoKeys: SafeStorageKeyProviding {
    func password(service: String) throws(CookieImportError) -> SecretBytes {
        Issue.record("Firefox import asked the Keychain for \(service)")
        throw .keyNotFound(service: service)
    }
}

/// A synthetic Firefox profile: `key4.db` sealed with a random global salt
/// and master key under `primaryPassword`, and `logins.json` under that key.
struct FirefoxFixture {
    enum KeyScheme { case pbes2, sha1TripleDES }
    enum Cipher { case aes, tripleDES }

    struct Login {
        var hostname: String
        var username: String
        var password: String
        var cipher: Cipher = .aes
        var httpRealm: String?
        var corrupt = false
        var created: Double = 1_700_000_000_000
    }

    let home: FixtureHome
    let profile: URL
    let primaryPassword: String
    let masterKey = SecretBytes(copying: (0..<32).map { _ in UInt8.random(in: 0...255) })
    static let keyID: [UInt8] = [0xF8] + [UInt8](repeating: 0, count: 14) + [0x01]

    init(primaryPassword: String, keyScheme: KeyScheme) throws {
        home = try FixtureHome()
        profile = home.directory(.firefox).appending(path: "Profiles/abc.default", directoryHint: .isDirectory)
        self.primaryPassword = primaryPassword
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let salt = (0..<20).map { _ in UInt8.random(in: 0...255) }
        let password = SecretBytes(copying: Array(primaryPassword.utf8))
        let check = try Self.seal(Array("password-check".utf8), salt: salt, password: password, scheme: keyScheme)
        let key = try Self.seal(masterKey.withUnsafeBytes { Array($0) }, salt: salt, password: password, scheme: keyScheme)
        try FixtureHome.sqlite(profile.appending(path: "key4.db"), [
            "CREATE TABLE metaData (id PRIMARY KEY UNIQUE ON CONFLICT REPLACE, item1, item2)",
            "INSERT INTO metaData VALUES ('password', \(Self.hex(salt)), \(Self.hex(check)))",
            "CREATE TABLE nssPrivate (id PRIMARY KEY UNIQUE ON CONFLICT ABORT, a11, a102)",
            "INSERT INTO nssPrivate VALUES (1, \(Self.hex(key)), \(Self.hex(Self.keyID)))",
        ])
    }

    func writeLogins(_ logins: [Login]) throws {
        let entries = try logins.map { login -> [String: Any] in
            var entry: [String: Any] = [
                "hostname": login.hostname, "formSubmitURL": login.hostname, "timeCreated": login.created,
                "encryptedUsername": try seal(login.username, login.cipher),
                "encryptedPassword": login.corrupt ? Data([0x30, 0x03, 0x04, 0x01, 0x00]).base64EncodedString() : try seal(login.password, login.cipher),
            ]
            entry["httpRealm"] = login.httpRealm ?? NSNull()
            return entry
        }
        let data = try JSONSerialization.data(withJSONObject: ["nextId": logins.count + 1, "logins": entries, "version": 3])
        try data.write(to: profile.appending(path: "logins.json"))
    }

    private func seal(_ text: String, _ cipher: Cipher) throws -> String {
        let (algorithm, oid, keyLength, ivLength) = cipher == .aes
            ? (CCAlgorithm(kCCAlgorithmAES), FirefoxPasswordCrypto.aes256CBC, kCCKeySizeAES256, kCCBlockSizeAES128)
            : (CCAlgorithm(kCCAlgorithm3DES), FirefoxPasswordCrypto.tripleDESCBC, kCCKeySize3DES, kCCBlockSize3DES)
        let iv = (0..<ivLength).map { _ in UInt8.random(in: 0...255) }
        let sealed = try FirefoxPasswordCrypto.crypt(algorithm, key: masterKey, keyLength: keyLength, iv: iv, Array(text.utf8),
                                                     operation: CCOperation(kCCEncrypt))
        let der = DERWriter.sequence([DERWriter.octets(Self.keyID), DERWriter.sequence([DERWriter.oid(oid), DERWriter.octets(iv)]),
                                      DERWriter.octets(sealed.withUnsafeBytes { Array($0) })])
        return Data(der).base64EncodedString()
    }

    static func seal(_ plain: [UInt8], salt: [UInt8], password: SecretBytes, scheme: KeyScheme) throws -> [UInt8] {
        let hashed = FirefoxPasswordCrypto.sha1([salt], secret: password)
        switch scheme {
        case .pbes2:
            let entrySalt = (0..<32).map { _ in UInt8.random(in: 0...255) }
            let iv14 = (0..<14).map { _ in UInt8.random(in: 0...255) }
            let iterations = 1000
            let key = SecretBytes(capacity: 32) { out in
                hashed.withUnsafeBytes { pw in
                    _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: Int8.self), pw.count,
                                             entrySalt, entrySalt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                             out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
                return 32
            }
            let sealed = try FirefoxPasswordCrypto.crypt(CCAlgorithm(kCCAlgorithmAES), key: key, keyLength: 32, iv: [0x04, 0x0E] + iv14, plain,
                                                         operation: CCOperation(kCCEncrypt))
            let parameters = DERWriter.sequence([
                DERWriter.sequence([DERWriter.oid(FirefoxPasswordCrypto.pbkdf2), DERWriter.sequence([
                    DERWriter.octets(entrySalt), DERWriter.integer(iterations), DERWriter.integer(32),
                    DERWriter.sequence([DERWriter.oid(FirefoxPasswordCrypto.hmacSHA256), [0x05, 0x00]]),
                ])]),
                DERWriter.sequence([DERWriter.oid(FirefoxPasswordCrypto.aes256CBC), DERWriter.octets(iv14)]),
            ])
            return DERWriter.sequence([DERWriter.sequence([DERWriter.oid(FirefoxPasswordCrypto.pbes2), parameters]),
                                       DERWriter.octets(sealed.withUnsafeBytes { Array($0) })])
        case .sha1TripleDES:
            let entrySalt = (0..<20).map { _ in UInt8.random(in: 0...255) }
            let (key, iv) = FirefoxPasswordCrypto.tripleDESKey(hashed: hashed, entrySalt: entrySalt)
            let sealed = try FirefoxPasswordCrypto.crypt(CCAlgorithm(kCCAlgorithm3DES), key: key, keyLength: kCCKeySize3DES, iv: iv, plain,
                                                         operation: CCOperation(kCCEncrypt))
            return DERWriter.sequence([
                DERWriter.sequence([DERWriter.oid(FirefoxPasswordCrypto.sha1TripleDES),
                                    DERWriter.sequence([DERWriter.octets(entrySalt), DERWriter.integer(1)])]),
                DERWriter.octets(sealed.withUnsafeBytes { Array($0) }),
            ])
        }
    }

    static func hex(_ bytes: [UInt8]) -> String { "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'" }
}

/// Just enough DER to write NSS fixtures.
struct DERWriter {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        if count < 0x80 { return [tag, UInt8(count)] + content }
        var length: [UInt8] = []
        var remaining = count
        while remaining > 0 { length.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 }
        return [tag, 0x80 | UInt8(length.count)] + length + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        var bytes = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var chunk = [UInt8(part & 0x7F)]
            var rest = part >> 7
            while rest > 0 { chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
            bytes += chunk
        }
        return tlv(0x06, bytes)
    }
}
