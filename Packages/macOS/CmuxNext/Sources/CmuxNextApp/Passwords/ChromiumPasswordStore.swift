import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation

/// The real store: Chromium's password store of each cmux browser profile, reached through
/// the CEF fork (passwords.md section 2). Saved passwords, never-save sites, reveal and export
/// use the fork password core (API 18: `cmux_password_list` and the calls after it); passkeys
/// use `cmux_profile_passkeys_list` / `_delete`. A fork without a call answers
/// ``PasswordStoreError/unavailable``, and the page says "Available after the next update".
@MainActor
final class ChromiumPasswordStore: PasswordStore {
    /// The Chromium calls, nil when this build has no Chromium (or the browser is off).
    private let core: () -> (any ChromiumPasswordCore)?
    private var listeners: [UUID: @MainActor (String) -> Void] = [:]

    init(core: @escaping () -> (any ChromiumPasswordCore)?) {
        self.core = core
    }

    convenience init(engine: @escaping () -> CEFEngine?) {
        self.init(core: { engine() })
    }

    func capabilities() async -> PasswordStoreCapabilities {
        guard let core = core() else { return .unsupported }
        let passwords = await core.canManagePasswords()
        let passkeys = await core.canManagePasskeys()
        return PasswordStoreCapabilities(passwords: passwords, passkeys: passkeys, exceptions: passwords, export: passwords)
    }

    // MARK: Saved passwords (fork API 18)

    func passwords(profile: String) async throws -> [SavedPassword] {
        let (core, store) = try await passwordTarget(profile)
        return try await mapped { try await core.passwordList(in: store) }.passwords.map {
            SavedPassword(id: $0.id, site: $0.site, url: $0.url, username: $0.username, created: $0.created, lastUsed: $0.lastUsed,
                          timesUsed: $0.timesUsed, weak: $0.weak, reused: $0.reused)
        }
    }

    func exceptions(profile: String) async throws -> [PasswordException] {
        let (core, store) = try await passwordTarget(profile)
        return try await mapped { try await core.passwordList(in: store) }.exceptions.map { PasswordException(id: $0.id, site: $0.site) }
    }

    func removePasswords(_ ids: [String], profile: String) async throws -> Int {
        let (core, store) = try await passwordTarget(profile)
        let removed = try await mapped { try await core.removePasswords(ids, in: store) }
        guard removed >= 0 else { throw PasswordStoreError.failed(PasswordStrings.storeFailed) }
        if removed > 0 { notify(profile) }
        return removed
    }

    func setUsername(_ username: String, id: String, profile: String) async throws {
        let (core, store) = try await passwordTarget(profile)
        switch try await mapped({ try await core.setPasswordUsername(username, id: id, in: store) }) {
        case 1: notify(profile)
        case 0: throw PasswordStoreError.notFound
        case -2: throw PasswordStoreError.failed(PasswordStrings.usernameTaken)
        default: throw PasswordStoreError.failed(PasswordStrings.storeFailed)
        }
    }

    func removeException(_ id: String, profile: String) async throws -> Bool {
        let (core, store) = try await passwordTarget(profile)
        let result = try await mapped { try await core.removePasswordException(id, in: store) }
        guard result >= 0 else { throw PasswordStoreError.failed(PasswordStrings.storeFailed) }
        if result == 1 { notify(profile) }
        return result == 1
    }

    /// The bytes go straight from the shim's buffer into SecretBytes (page-aligned, locked,
    /// zeroed on release); the shim zeroes its own buffer after the copy.
    func password(_ id: String, profile: String) async throws -> SecretBytes {
        let (core, store) = try await passwordTarget(profile)
        var secret: SecretBytes?
        let found = try await mapped {
            try await core.revealPassword(id, in: store) { bytes in
                secret = SecretBytes(capacity: bytes.count) { buffer in
                    buffer.copyMemory(from: bytes)
                    return bytes.count
                }
            }
        }
        guard found, let secret else { throw PasswordStoreError.notFound }
        return secret
    }

    func export(profile: String, to url: URL) async throws -> Int {
        let (core, store) = try await passwordTarget(profile)
        let written = try await mapped { try await core.exportPasswords(in: store, to: url) }
        guard written >= 0 else { throw PasswordStoreError.failed(PasswordStrings.storeFailed) }
        return written
    }

    // MARK: Passkeys

    func passkeys(profile: String) async throws -> [SavedPasskey] {
        let (core, store) = try await passkeyTarget(profile)
        return try await mapped { try await core.passkeys(in: store) }.map {
            SavedPasskey(id: $0.credentialID, relyingParty: $0.relyingParty, userName: $0.userName, userDisplayName: $0.userDisplayName)
        }
    }

    func removePasskey(_ id: String, profile: String) async throws -> Bool {
        let (core, store) = try await passkeyTarget(profile)
        let deleted = try await mapped { try await core.deletePasskey(id, in: store) }
        if deleted { notify(profile) }
        return deleted
    }

    func counts(profile: String) async -> PasswordCounts {
        let passwords = try? await self.passwords(profile: profile).count
        let passkeys = try? await self.passkeys(profile: profile).count
        return PasswordCounts(passwords: passwords, passkeys: passkeys)
    }

    func observe(_ onChange: @escaping @MainActor (String) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = onChange
        return { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    private func notify(_ profile: String) {
        for listener in listeners.values { listener(profile) }
    }

    /// The fork's errors as store errors; ``PasswordStoreError`` passes through.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as PasswordStoreError {
            throw error
        } catch ChromiumPasskeyError.unavailable {
            throw PasswordStoreError.unavailable
        } catch {
            throw PasswordStoreError.failed(PasswordStrings.storeFailed)
        }
    }

    private func passwordTarget(_ profile: String) async throws -> (any ChromiumPasswordCore, BrowserProfileID) {
        guard let core = core(), await core.canManagePasswords() else { throw PasswordStoreError.unavailable }
        return (core, try Self.engineProfile(profile))
    }

    private func passkeyTarget(_ profile: String) async throws -> (any ChromiumPasswordCore, BrowserProfileID) {
        guard let core = core(), await core.canManagePasskeys() else { throw PasswordStoreError.unavailable }
        return (core, try Self.engineProfile(profile))
    }

    private static func engineProfile(_ profile: String) throws -> BrowserProfileID {
        guard let store = BrowserProfileRecord.engineProfile(for: profile) else { throw PasswordStoreError.notFound }
        return store
    }
}

/// The CEF engine is the live password core.
extension CEFEngine: ChromiumPasswordCore {}
