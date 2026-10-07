import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation

/// The real store: Chromium's password store of each cmux browser profile, reached through
/// the CEF fork (passwords.md section 2). Passkeys come from fork API 18
/// (`cmux_profile_passkeys_list`, `cmux_profile_passkey_delete`). Saved passwords, exceptions
/// and export need the fork password-core API (cmux.18 batch, step B of the password lead);
/// until it ships every such call answers ``PasswordStoreError/unavailable``, and the page says
/// "Available after the next update".
@MainActor
final class ChromiumPasswordStore: PasswordStore {
    /// The CEF engine, nil when this build has no Chromium (or the browser is off).
    private let engine: () -> CEFEngine?
    private var listeners: [UUID: @MainActor (String) -> Void] = [:]

    init(engine: @escaping () -> CEFEngine?) {
        self.engine = engine
    }

    func capabilities() async -> PasswordStoreCapabilities {
        let passkeys = await engine()?.canManagePasskeys() ?? false
        return PasswordStoreCapabilities(passwords: false, passkeys: passkeys, exceptions: false, export: false)
    }

    func passwords(profile: String) async throws -> [SavedPassword] { throw PasswordStoreError.unavailable }
    func exceptions(profile: String) async throws -> [PasswordException] { throw PasswordStoreError.unavailable }
    func removePasswords(_ ids: [String], profile: String) async throws -> Int { throw PasswordStoreError.unavailable }
    func setUsername(_ username: String, id: String, profile: String) async throws { throw PasswordStoreError.unavailable }
    func removeException(_ id: String, profile: String) async throws -> Bool { throw PasswordStoreError.unavailable }
    func password(_ id: String, profile: String) async throws -> SecretBytes { throw PasswordStoreError.unavailable }
    func export(profile: String, to url: URL) async throws -> Int { throw PasswordStoreError.unavailable }

    func passkeys(profile: String) async throws -> [SavedPasskey] {
        let (engine, store) = try await passkeyTarget(profile)
        do {
            return try await engine.passkeys(in: store).map {
                SavedPasskey(id: $0.credentialID, relyingParty: $0.relyingParty, userName: $0.userName, userDisplayName: $0.userDisplayName)
            }
        } catch ChromiumPasskeyError.unavailable {
            throw PasswordStoreError.unavailable
        } catch {
            throw PasswordStoreError.failed(String(describing: error))
        }
    }

    func removePasskey(_ id: String, profile: String) async throws -> Bool {
        let (engine, store) = try await passkeyTarget(profile)
        let deleted: Bool
        do {
            deleted = try await engine.deletePasskey(id, in: store)
        } catch ChromiumPasskeyError.unavailable {
            throw PasswordStoreError.unavailable
        } catch {
            throw PasswordStoreError.failed(String(describing: error))
        }
        if deleted { notify(profile) }
        return deleted
    }

    func counts(profile: String) async -> PasswordCounts {
        let passkeys = try? await self.passkeys(profile: profile).count
        return PasswordCounts(passwords: nil, passkeys: passkeys)
    }

    func observe(_ onChange: @escaping @MainActor (String) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = onChange
        return { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    private func notify(_ profile: String) {
        for listener in listeners.values { listener(profile) }
    }

    private func passkeyTarget(_ profile: String) async throws -> (CEFEngine, BrowserProfileID) {
        guard let engine = engine(), await engine.canManagePasskeys() else { throw PasswordStoreError.unavailable }
        guard let store = BrowserProfileRecord.engineProfile(for: profile) else { throw PasswordStoreError.notFound }
        return (engine, store)
    }
}
