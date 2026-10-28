import Foundation

extension CEFEngine {
    /// Whether this build's Chromium can store imported passwords (fork API
    /// 15). Starts Chromium when it is not running yet.
    public func canImportPasswords() async -> Bool {
        do {
            try await startRuntime(trigger: "passwordImport")
        } catch {
            return false
        }
        return CEFRuntime.shared.canImportPasswords
    }

    /// Stores imported passwords in `profile`'s Chromium password store,
    /// skipping ones it already has. Every password in `rows` must stay alive
    /// until this returns.
    public func importPasswords(_ rows: ChromiumPasswordRows, into profile: BrowserProfileID) async throws -> ChromiumPasswordWriteResult {
        try await startRuntime(trigger: "passwordImport")
        return try await CEFRuntime.shared.importPasswords(rows, profile: profile)
    }

    /// Whether an import lists its conflicts and can replace them (fork API
    /// 20); false until Chromium runs.
    public var canReplacePasswords: Bool {
        let runtime = CEFRuntime.shared
        return runtime.canImportPasswords && runtime.shim?.passwordReplaceAvailable() == 1
    }

    /// Saves each row's password over the saved one for its sign-in in
    /// `profile`: the person's Replace for an import's conflicts (fork API
    /// 20). Every password in `rows` must stay alive until this returns.
    public func replacePasswords(_ rows: ChromiumPasswordRows, in profile: BrowserProfileID) async throws -> ChromiumPasswordReplaceResult {
        guard rows.count > 0 else { return ChromiumPasswordReplaceResult(updated: 0, missing: 0, rejected: 0) }
        let runtime = CEFRuntime.shared
        try await startRuntime(trigger: "passwordImport")
        guard let shim = runtime.shim, runtime.canImportPasswords, shim.passwordReplaceAvailable() == 1 else { throw BrowserTabError.closed }
        let reply = try await runtime.profileWrite(profile, label: "password replace", timeout: CEFRuntime.passwordImportTimeout) { path, id in
            let started = shim.replacePasswords(path, id, rows)
            rows.copied()
            return started
        }
        return ChromiumPasswordReplaceResult.parse(reply.json)
            ?? ChromiumPasswordReplaceResult(updated: Int(reply.value), missing: 0, rejected: 0)
    }
}
