import Foundation

extension SettingsController {
    /// Moves `sidebar.showWorkspaceDirectory` and `sidebar.showCounts` to
    /// their `sidebar.workspaceRow.*` keys in one atomic write, once at
    /// launch, so the file says what the sidebar draws. A set new key wins
    /// and the S1 key is dropped; a bad S1 value stays (with its diagnostic)
    /// until the user fixes it or writes the new toggle. Returns whether it
    /// wrote.
    @discardableResult
    public func migrateLegacyWorkspaceRowKeys() async throws -> Bool {
        var edits: [(path: [String], value: JSONValue?)] = []
        for element in WorkspaceRowElement.allCases {
            guard let legacy = WorkspaceRowSetting.legacyPaths[element], let old = try await file.value(at: legacy) else { continue }
            let path = WorkspaceRowSetting.path(element)
            if try await file.value(at: path) == nil {
                guard let on = old.boolValue else { continue }
                edits.append((path, .bool(on)))
            }
            edits.append((legacy, nil))
        }
        guard !edits.isEmpty else { return false }
        try await file.apply(edits)
        await reloadAfterWrite()
        return true
    }
}
