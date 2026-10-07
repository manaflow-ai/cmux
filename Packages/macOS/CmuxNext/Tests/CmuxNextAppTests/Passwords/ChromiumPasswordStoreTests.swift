@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation
import Testing

/// ChromiumPasswordStore on fork API 18 (plans/cmux-next/passwords.md 1.4): rows are metadata,
/// the fork's result codes become store errors, the revealed password lands in SecretBytes only,
/// every write notifies the page, and a fork without the calls stays "unavailable".
@MainActor struct ChromiumPasswordStoreTests {
    @MainActor final class FakeCore: ChromiumPasswordCore {
        var passwordsAvailable = true
        var list = ChromiumPasswordList(passwords: [
            .init(id: "7", site: "github.com", url: "https://github.com/", username: "octo", created: nil, lastUsed: nil,
                  timesUsed: 2, weak: false, reused: true),
        ], exceptions: [.init(id: "2", site: "bank.example")])
        var usernameResult = 1
        var removeResult = 1
        var secret: [UInt8]? = Array("cmux-test-secret-reveal".utf8)
        var calls: [String] = []

        func canManagePasswords() async -> Bool { passwordsAvailable }
        func canManagePasskeys() async -> Bool { false }
        func passwordList(in profile: BrowserProfileID) async throws -> ChromiumPasswordList {
            calls.append("list")
            return list
        }
        func removePasswords(_ ids: [String], in profile: BrowserProfileID) async throws -> Int {
            calls.append("remove \(ids.joined(separator: ","))")
            return removeResult
        }
        func removePasswordException(_ id: String, in profile: BrowserProfileID) async throws -> Int {
            calls.append("exception \(id)")
            return 1
        }
        func setPasswordUsername(_ username: String, id: String, in profile: BrowserProfileID) async throws -> Int {
            calls.append("username \(id)=\(username)")
            return usernameResult
        }
        func revealPassword(_ id: String, in profile: BrowserProfileID, copy: @escaping (UnsafeRawBufferPointer) -> Void) async throws -> Bool {
            calls.append("reveal \(id)")
            guard let secret else { return false }
            secret.withUnsafeBytes(copy)
            return true
        }
        func exportPasswords(in profile: BrowserProfileID, to url: URL) async throws -> Int {
            calls.append("export \(url.lastPathComponent)")
            return 4
        }
        func passkeys(in profile: BrowserProfileID) async throws -> [ChromiumPasskey] { [] }
        func deletePasskey(_ credentialID: String, in profile: BrowserProfileID) async throws -> Bool { false }
    }

    @Test func listsSignInsAndExceptionsAsMetadata() async throws {
        let core = FakeCore()
        let store = ChromiumPasswordStore(core: { core })
        #expect(await store.capabilities() == PasswordStoreCapabilities(passwords: true, passkeys: false, exceptions: true, export: true))
        let rows = try await store.passwords(profile: "default")
        #expect(rows == [SavedPassword(id: "7", site: "github.com", url: "https://github.com/", username: "octo", created: nil,
                                       lastUsed: nil, timesUsed: 2, weak: false, reused: true)])
        #expect(try await store.exceptions(profile: "default") == [PasswordException(id: "2", site: "bank.example")])
        #expect(await store.counts(profile: "default").passwords == 1)
    }

    @Test func writesNotifyThePageAndMapTheForkCodes() async throws {
        let core = FakeCore()
        let store = ChromiumPasswordStore(core: { core })
        var changed: [String] = []
        let stop = store.observe { changed.append($0) }
        defer { stop() }
        #expect(try await store.removePasswords(["7"], profile: "default") == 1)
        try await store.setUsername("new", id: "7", profile: "default")
        #expect(try await store.removeException("2", profile: "default"))
        #expect(changed == ["default", "default", "default"])
        core.usernameResult = -2
        await #expect(throws: PasswordStoreError.failed(PasswordStrings.usernameTaken)) {
            try await store.setUsername("taken", id: "7", profile: "default")
        }
        core.usernameResult = 0
        await #expect(throws: PasswordStoreError.notFound) { try await store.setUsername("x", id: "8", profile: "default") }
        core.removeResult = -1
        await #expect(throws: PasswordStoreError.self) { _ = try await store.removePasswords(["7"], profile: "default") }
    }

    @Test func theRevealedPasswordGoesOnlyIntoSecretBytes() async throws {
        let core = FakeCore()
        let store = ChromiumPasswordStore(core: { core })
        let secret = try await store.password("7", profile: "default")
        #expect(secret.withUnsafeBytes { Array($0) } == Array("cmux-test-secret-reveal".utf8))
        core.secret = nil
        await #expect(throws: PasswordStoreError.notFound) { _ = try await store.password("8", profile: "default") }
        #expect(try await store.export(profile: "default", to: URL(fileURLWithPath: "/tmp/out.csv")) == 4)
    }

    @Test func aForkWithoutTheCallsStaysUnavailable() async {
        let core = FakeCore()
        core.passwordsAvailable = false
        let store = ChromiumPasswordStore(core: { core })
        #expect(await store.capabilities() == .unsupported)
        await #expect(throws: PasswordStoreError.unavailable) { _ = try await store.passwords(profile: "default") }
        #expect(core.calls.isEmpty)
    }
}
