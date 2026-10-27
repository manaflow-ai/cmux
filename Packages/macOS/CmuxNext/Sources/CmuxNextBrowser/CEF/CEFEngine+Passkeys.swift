import Foundation

/// The Passwords page's passkey section (plans/cmux-next/passwords.md 1.4): the fork's
/// `cmux_profile_passkeys_list` and `cmux_profile_passkey_delete` (API 18) through the shim.
/// Each call starts Chromium when it is not running yet.
extension CEFEngine {
    /// The first fork API with profile passkey calls.
    static let passkeysForkAPI: Int32 = 18
    static let passkeyTimeout: Duration = .seconds(30)

    /// Whether this build's Chromium can list and delete profile passkeys.
    public func canManagePasskeys() async -> Bool {
        do {
            try await startRuntime(trigger: "passkeys")
        } catch {
            return false
        }
        return Self.passkeyShim() != nil
    }

    /// The profile passkeys of `profile` (metadata only).
    public func passkeys(in profile: BrowserProfileID) async throws -> [ChromiumPasskey] {
        try await startRuntime(trigger: "passkeys")
        guard let shim = Self.passkeyShim() else { throw ChromiumPasskeyError.unavailable }
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "passkey list", timeout: Self.passkeyTimeout) { path, id in
            shim.passkeysList(path, id)
        }
        guard reply.value == 1, let rows = ChromiumPasskey.parse(reply.json) else { throw ChromiumPasskeyError.keychainUnreadable }
        return rows
    }

    /// Deletes one profile passkey; true when Chromium deleted it.
    public func deletePasskey(_ credentialID: String, in profile: BrowserProfileID) async throws -> Bool {
        try await startRuntime(trigger: "passkeys")
        guard let shim = Self.passkeyShim(), !credentialID.isEmpty else { throw ChromiumPasskeyError.unavailable }
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "passkey delete", timeout: Self.passkeyTimeout) { path, id in
            shim.passkeyDelete(path, credentialID, id)
        }
        return reply.value == 1
    }

    /// Host mode's iCloud Keychain relay (task p01-process-067, feature `chromiumHostPasskeys`), for `debug.cef`
    /// `host_passkeys` (chromium-host-bench.py `--native-ui` passkey row): whether the host took the handler, the
    /// listing permission and what the relay did. Counts and states only, never a request. Nil without the relay.
    public var hostPasskeyCounters: [String: Double]? {
        guard let relay = CEFRuntime.shared.hostStart?.platformPasskeys else { return nil }
        let stats = relay.stats
        var counters: [String: Double] = [
            "handler_set": stats.handlerSet ? 1 : 0, "permission": Double(stats.permission.rawValue),
            "requests": Double(stats.requests), "cancels": Double(stats.cancels), "sheets": Double(stats.sheets),
            "answered": Double(stats.answered),
        ]
        for (refusal, count) in stats.refused { counters["refused_" + refusal] = Double(count) }
        return counters
    }

    /// The loaded shim when the running fork has both passkey calls (API 18), else nil.
    private static func passkeyShim() -> CEFShimLibrary? {
        let runtime = CEFRuntime.shared
        guard let shim = runtime.shim, runtime.state == .ready, runtime.forkAPIVersion >= passkeysForkAPI,
              shim.passkeysAvailable() == 1 else { return nil }
        return shim
    }
}
