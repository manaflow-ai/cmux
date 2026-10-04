/// `picker.pinned` in cmux.json (R89): folders the cmux picker lists under
/// Locations, after the standard ones. An array of absolute paths or
/// `~/...` paths (home expanded here). A missing key is no pins; a value
/// that is not an array of strings is no pins plus a diagnostic, and a
/// relative entry is dropped with one.
public enum PickerPinnedSetting {
    public nonisolated static let configPath = ["picker", "pinned"]

    nonisolated static func parse(_ root: JSONValue, home: String) -> ([String], [SettingsDiagnostic]) {
        guard let value = root.value(at: configPath) else { return ([], []) }
        let path = configPath.joined(separator: ".")
        guard let items = value.arrayValue else {
            return ([], [SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an array of folder paths")])
        }
        var pinned: [String] = []
        var diagnostics: [SettingsDiagnostic] = []
        for item in items {
            guard let text = item.stringValue, text.hasPrefix("/") || text.hasPrefix("~/") else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an absolute or ~/ path"))
                continue
            }
            pinned.append(text.hasPrefix("~/") ? home + String(text.dropFirst(1)) : text)
        }
        return (pinned, diagnostics)
    }
}
