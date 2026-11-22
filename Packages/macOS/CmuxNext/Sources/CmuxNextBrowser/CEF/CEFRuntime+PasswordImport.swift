import Foundation

/// Browser import: saved passwords into a profile's Chromium password store
/// (shim `cmux_shim_import_passwords`, fork API 15), also for a profile no
/// tab has opened yet. Per-tab filling is `CEFTab+PasswordFill`.
extension CEFRuntime {
    static let passwordImportTimeout: Duration = .seconds(60)

    /// Whether the running fork can write passwords, under cmux's own Keychain key.
    var canImportPasswords: Bool {
        guard let shim, state == .ready, !PasswordImportKey.storesUnderMockKey() else { return false }
        return shim.passwordImportAvailable() == 1 && Int(shim.passwordEntrySize()) == ChromiumPasswordRows.stride
    }

    func importPasswords(_ rows: ChromiumPasswordRows, profile: BrowserProfileID) async throws -> ChromiumPasswordWriteResult {
        guard rows.count > 0 else { return ChromiumPasswordWriteResult(added: 0, duplicate: 0, conflict: 0, rejected: 0) }
        guard let shim, canImportPasswords else { throw BrowserTabError.closed }
        // The shim copies every row before it returns: the passwords are zeroed then, not when the store replies.
        let reply = try await profileWrite(profile, label: "password import", timeout: Self.passwordImportTimeout) { path, id in
            let started = shim.importPasswords(path, id, UnsafeRawPointer(rows.rows), Int32(rows.count))
            rows.copied()
            return started
        }
        return ChromiumPasswordWriteResult.parse(reply.json)
            ?? ChromiumPasswordWriteResult(added: Int(reply.value), duplicate: 0, conflict: 0, rejected: 0)
    }
}

/// Whether imported passwords would be stored under a key anyone knows.
enum PasswordImportKey {
    /// Development bundles (and CMUX_MOCK_KEYCHAIN=1) run Chromium with its
    /// mock Keychain, whose key is a public constant: passwords stored there
    /// are as good as plaintext on disk, so the import is off. Debug builds may
    /// allow it for throwaway test data only (CMUX_NEXT_PASSWORD_IMPORT_MOCK_KEY=throwaway).
    static func storesUnderMockKey(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard CEFSwitches.current(forkAPIVersion: 0, bundleIdentifier: bundleIdentifier, environment: environment).useMockKeychain else { return false }
        #if DEBUG
        return environment["CMUX_NEXT_PASSWORD_IMPORT_MOCK_KEY"] != "throwaway"
        #else
        return true
        #endif
    }
}
