import Foundation

extension CEFEngine {
    /// Whether this build's Chromium can store imported passwords (fork API
    /// 15). Starts Chromium when it is not running yet.
    public func canImportPasswords() async -> Bool {
        do {
            try await CEFRuntime.shared.start(layout: layout, trigger: "passwordImport")
        } catch {
            return false
        }
        return CEFRuntime.shared.canImportPasswords
    }

    /// Stores imported passwords in `profile`'s Chromium password store,
    /// skipping ones it already has. Every password in `rows` must stay alive
    /// until this returns.
    public func importPasswords(_ rows: ChromiumPasswordRows, into profile: BrowserProfileID) async throws -> ChromiumPasswordWriteResult {
        try await CEFRuntime.shared.start(layout: layout, trigger: "passwordImport")
        return try await CEFRuntime.shared.importPasswords(rows, profile: profile)
    }
}
