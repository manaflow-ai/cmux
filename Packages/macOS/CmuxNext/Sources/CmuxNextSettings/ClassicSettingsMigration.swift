import Foundation

/// Classic cmux settings that cmux-next reads under another key. Next adopts the
/// classic `cmux.json` as is on first launch (`CmuxConfigFile.prepareDefaultURL`),
/// so without this a classic key next renamed is silently ignored and the
/// upgrade loses that setting (hq#1870 parity audit, cx-iy8b7). The renames and
/// their value maps live in Rust (cmux-config `migrations::classic`, `migrate.classic`).
extension SettingsController {
    /// Moves each classic key Rust lists to its next key in one atomic write,
    /// once at launch. A value next's descriptor accepts is written and the
    /// classic key dropped; a next key already set wins and the classic key is
    /// dropped; a classic value next can't express stays. Returns whether it wrote.
    @discardableResult
    public func migrateClassicSettings() async throws -> Bool {
        let document = try await file.document()
        let reply = try SettingsRust.call("migrate.classic", ["file": document])
        let edits: [(path: [String], value: JSONValue?)] = (reply["edits"]?.arrayValue ?? []).compactMap { edit in
            guard let path = edit["path"]?.arrayValue?.compactMap(\.stringValue), !path.isEmpty else { return nil }
            let value = edit["value"]
            return (path, value?.isNull == false ? value : nil)
        }
        guard !edits.isEmpty else { return false }
        try await file.apply(edits)
        await reloadAfterWrite()
        return true
    }
}
