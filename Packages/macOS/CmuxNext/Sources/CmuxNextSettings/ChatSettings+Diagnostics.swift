/// cmux.json checks for the `agents.chats.*` keys. The values reach the daemon
/// through `ChatSettings` (effective layers); this reports a value the schema
/// refuses at its key, so a typo in cmux.json is not silently read as the default.
extension ChatSettings {
    static func validate(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) {
        for key in booleanKeys + ["agents.chats.roots"] {
            let path = key.split(separator: ".").map(String.init)
            guard let value = root.value(at: path), let descriptor = SettingsSchema.descriptor(for: path),
                  !descriptor.accepts(value) else { continue }
            let expected = path == rootsPath ? "a list of absolute folder paths (starting with / or ~/)" : "true or false"
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: key, message: "expected \(expected)"))
        }
    }
}
