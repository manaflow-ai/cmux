extension SettingsController {
    /// Copies the code editor's defaults taken from another editor (`imported`, an `editor` section
    /// from ``EditorSettingsImport``) into cmux.json: every Settings row's key that cmux.json does
    /// not set yet, through the one write path (``setSetting(at:to:by:)``) as `writer`. A key
    /// cmux.json already has stays as it is. Language blocks and key bindings stay live (they have no
    /// Settings row). Which keys come over is `import.editor_copy`'s answer. Returns how many keys it wrote.
    ///
    /// - Parameters:
    ///   - imported: The mapped section (``EditorSettingsSources/Found/section``).
    ///   - writer: Who asked (a person in Settings, the CLI, an agent).
    /// - Returns: The number of keys written.
    /// - Throws: The first write the settings store refused.
    @discardableResult
    public func copyEditorSettings(_ imported: JSONValue, by writer: SettingWriter) async throws -> Int {
        let reply = try SettingsRust.call("import.editor_copy", ["imported": imported, "file": fileRoot])
        var written = 0
        for write in reply["writes"]?.arrayValue ?? [] {
            guard let path = write["path"]?.arrayValue?.compactMap(\.stringValue), let value = write["value"] else { continue }
            try await setSetting(at: path, to: value, by: writer)
            written += 1
        }
        return written
    }
}
