extension SettingsController {
    /// Copies the code editor's defaults taken from another editor (`imported`, an `editor` section
    /// from ``EditorSettingsSources``) into cmux.json: every Settings row's key that cmux.json does
    /// not set yet (Rust `import.editor_copy` picks them), through the one write path as `writer`.
    /// Returns how many keys it wrote.
    ///
    /// - Throws: The first write the settings store refused.
    @discardableResult
    public func copyEditorSettings(_ imported: JSONValue, by writer: SettingWriter) async throws -> Int {
        let reply = try SettingsRust.call("import.editor_copy", .object(["imported": imported, "file": fileRoot]))
        let writes = reply["writes"]?.arrayValue ?? []
        for write in writes {
            let path = (write["path"]?.arrayValue ?? []).compactMap(\.stringValue)
            try await setSetting(at: path, to: write["value"], by: writer)
        }
        return writes.count
    }
}
