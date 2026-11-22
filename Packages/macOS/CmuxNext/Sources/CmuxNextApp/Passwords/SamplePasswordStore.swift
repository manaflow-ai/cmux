#if DEBUG
import CmuxNextBrowserImport
import Foundation

/// An in-memory store with made-up sign-ins for DEBUG builds only: the Passwords page dev
/// loop (`CMUX_NEXT_PASSWORDS_SAMPLE=1` in a tagged DEV build) and the provider tests. It is
/// compiled out of release builds, so a shipped app can never show sample data.
@MainActor
final class SamplePasswordStore: PasswordStore {
    var capabilitiesValue = PasswordStoreCapabilities(passwords: true, passkeys: true, exceptions: true, export: true)
    var savedPasswords: [String: [SavedPassword]]
    var savedPasskeys: [String: [SavedPasskey]]
    var savedExceptions: [String: [PasswordException]]
    /// The made-up password of each sign-in id.
    private var secrets: [String: String]
    /// Every write in order (tests).
    private(set) var writes: [String] = []
    private var listeners: [UUID: @MainActor (String) -> Void] = [:]

    init(profile: String = "default") {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        savedPasswords = [profile: [
            SavedPassword(id: "p1", site: "github.com", url: "https://github.com/login", username: "octo@example.com",
                          created: base - 90 * day, lastUsed: base - day, timesUsed: 41, weak: false, reused: false),
            SavedPassword(id: "p2", site: "github.com", url: "https://github.com/login", username: "octo-work",
                          created: base - 30 * day, lastUsed: base - 3 * day, timesUsed: 7, weak: false, reused: true),
            SavedPassword(id: "p3", site: "example.org", url: "https://example.org/sign-in", username: "sample",
                          created: base - 400 * day, lastUsed: nil, timesUsed: 0, weak: true, reused: true),
            SavedPassword(id: "p4", site: "news.example.com", url: "https://news.example.com/", username: "reader",
                          created: base - 10 * day, lastUsed: base - 10 * day, timesUsed: 1, weak: false, reused: false),
        ]]
        savedPasskeys = [profile: [
            SavedPasskey(id: "cred-1", relyingParty: "webauthn.io", userName: "sample", userDisplayName: "Sample Person"),
        ]]
        savedExceptions = [profile: [PasswordException(id: "e1", site: "bank.example.com")]]
        secrets = ["p1": "sample-pass-1", "p2": "sample-pass-1", "p3": "123456", "p4": "sample-pass-4"]
    }

    func capabilities() async -> PasswordStoreCapabilities { capabilitiesValue }

    func passwords(profile: String) async throws -> [SavedPassword] {
        guard capabilitiesValue.passwords else { throw PasswordStoreError.unavailable }
        return savedPasswords[profile] ?? []
    }

    func passkeys(profile: String) async throws -> [SavedPasskey] {
        guard capabilitiesValue.passkeys else { throw PasswordStoreError.unavailable }
        return savedPasskeys[profile] ?? []
    }

    func exceptions(profile: String) async throws -> [PasswordException] {
        guard capabilitiesValue.exceptions else { throw PasswordStoreError.unavailable }
        return savedExceptions[profile] ?? []
    }

    func removePasswords(_ ids: [String], profile: String) async throws -> Int {
        guard capabilitiesValue.passwords else { throw PasswordStoreError.unavailable }
        let before = savedPasswords[profile]?.count ?? 0
        savedPasswords[profile]?.removeAll { ids.contains($0.id) }
        return changed("remove", profile, before - (savedPasswords[profile]?.count ?? 0))
    }

    func setUsername(_ username: String, id: String, profile: String) async throws {
        guard capabilitiesValue.passwords else { throw PasswordStoreError.unavailable }
        guard let index = savedPasswords[profile]?.firstIndex(where: { $0.id == id }) else { throw PasswordStoreError.notFound }
        savedPasswords[profile]?[index].username = username
        _ = changed("username", profile, 1)
    }

    func removeException(_ id: String, profile: String) async throws -> Bool {
        guard capabilitiesValue.exceptions else { throw PasswordStoreError.unavailable }
        let before = savedExceptions[profile]?.count ?? 0
        savedExceptions[profile]?.removeAll { $0.id == id }
        return changed("exception.remove", profile, before - (savedExceptions[profile]?.count ?? 0)) > 0
    }

    func removePasskey(_ id: String, profile: String) async throws -> Bool {
        guard capabilitiesValue.passkeys else { throw PasswordStoreError.unavailable }
        let before = savedPasskeys[profile]?.count ?? 0
        savedPasskeys[profile]?.removeAll { $0.id == id }
        return changed("passkey.remove", profile, before - (savedPasskeys[profile]?.count ?? 0)) > 0
    }

    func password(_ id: String, profile: String) async throws -> SecretBytes {
        guard capabilitiesValue.passwords else { throw PasswordStoreError.unavailable }
        guard savedPasswords[profile]?.contains(where: { $0.id == id }) == true, let secret = secrets[id] else {
            throw PasswordStoreError.notFound
        }
        return SecretBytes(copying: Array(secret.utf8))
    }

    func export(profile: String, to url: URL) async throws -> Int {
        guard capabilitiesValue.export else { throw PasswordStoreError.unavailable }
        let rows = savedPasswords[profile] ?? []
        var csv = "name,url,username,password\n"
        for row in rows { csv += "\(row.site),\(row.url),\(row.username),\(secrets[row.id] ?? "")\n" }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(csv.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw PasswordStoreError.failed("could not write \(url.lastPathComponent)")
        }
        writes.append("export")
        return rows.count
    }

    func counts(profile: String) async -> PasswordCounts {
        PasswordCounts(passwords: capabilitiesValue.passwords ? savedPasswords[profile]?.count ?? 0 : nil,
                       passkeys: capabilitiesValue.passkeys ? savedPasskeys[profile]?.count ?? 0 : nil)
    }

    func observe(_ onChange: @escaping @MainActor (String) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = onChange
        return { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    private func changed(_ write: String, _ profile: String, _ count: Int) -> Int {
        writes.append(write)
        if count > 0 { for listener in listeners.values { listener(profile) } }
        return count
    }
}
#endif
