import Foundation

/// Browser import: saved passwords into a profile's Chromium password store
/// (shim `cmux_shim_import_passwords`, fork API 15), also for a profile no
/// tab has opened yet. Per-tab filling is `CEFTab+PasswordFill`.
extension CEFRuntime {
    static let passwordImportTimeout: Duration = .seconds(60)

    /// Whether the running fork can write passwords.
    var canImportPasswords: Bool {
        guard let shim, state == .ready else { return false }
        return shim.passwordImportAvailable() == 1 && Int(shim.passwordEntrySize()) == ChromiumPasswordRows.stride
    }

    func importPasswords(_ rows: ChromiumPasswordRows, profile: BrowserProfileID) async throws -> ChromiumPasswordWriteResult {
        guard rows.count > 0 else { return ChromiumPasswordWriteResult(added: 0, duplicate: 0, conflict: 0, rejected: 0) }
        guard let shim, canImportPasswords else { throw BrowserTabError.closed }
        // The shim copies every row before it returns; the caller may zero its passwords after that.
        let reply = try await profileWrite(profile, label: "password import", timeout: Self.passwordImportTimeout) { path, id in
            shim.importPasswords(path, id, UnsafeRawPointer(rows.rows), Int32(rows.count))
        }
        return ChromiumPasswordWriteResult.parse(reply.json)
            ?? ChromiumPasswordWriteResult(added: Int(reply.value), duplicate: 0, conflict: 0, rejected: 0)
    }
}
