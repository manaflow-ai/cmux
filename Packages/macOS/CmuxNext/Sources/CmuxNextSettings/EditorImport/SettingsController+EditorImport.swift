extension SettingsController {
    /// Copies the code editor's defaults taken from another editor (`imported`, an `editor` section
    /// from ``EditorSettingsImport``) into cmux.json: every Settings row's key that cmux.json does
    /// not set yet, through the one write path (``setSetting(_:to:by:)``) as `writer`. A key
    /// cmux.json already has stays as it is. Language blocks and key bindings stay live (they have no
    /// Settings row). Returns how many keys it wrote.
    ///
    /// - Parameters:
    ///   - imported: The mapped section (``EditorSettingsSources/Found/section``).
    ///   - writer: Who asked (a person in Settings, the CLI, an agent).
    /// - Returns: The number of keys written.
    /// - Throws: The first write the settings store refused.
    @discardableResult
    public func copyEditorSettings(_ imported: JSONValue, by writer: SettingWriter) async throws -> Int {
        var written = 0
        for descriptor in EditorSettingsSchema.descriptors where descriptor.path != EditorSettingsSchema.importFromPath {
            let key = Array(descriptor.path.dropFirst())
            guard let value = imported.value(at: key), descriptor.accepts(value),
                  fileRoot.value(at: descriptor.path) == nil else { continue }
            try await setSetting(descriptor, to: value, by: writer)
            written += 1
        }
        return written
    }
}
