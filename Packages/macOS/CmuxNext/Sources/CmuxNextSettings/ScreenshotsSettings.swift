// The paths and defaults are generated from schemas/settings/source/screenshots.json
// (Schema/SettingsSchema+Screenshots.generated.swift); this file only parses.

/// `screenshots.*` in cmux.json: what the Screenshots pane (`cmux://screenshots`) lists besides
/// the macOS screenshot folder and its preview folder. Screenshot apps are found unless the user
/// turns that off; `folders` adds folders (absolute or `~/` paths, home expanded here).
public nonisolated struct ScreenshotsSettings: Sendable, Equatable {
    /// List the folders of the screenshot apps found on this Mac.
    public var findTools = ScreenshotsSettings.findToolsDefault
    /// More folders to list, as absolute paths.
    public var folders = ScreenshotsSettings.foldersDefault

    /// The defaults: apps found, no more folders.
    public init() {}

    static func parse(_ root: JSONValue, home: String, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        if let value = root.value(at: findToolsPath) {
            if let flag = value.boolValue {
                settings.findTools = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: findToolsPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        guard let value = root.value(at: foldersPath) else { return settings }
        let path = foldersPath.joined(separator: ".")
        guard let items = value.arrayValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an array of folder paths"))
            return settings
        }
        settings.folders = items.compactMap { item in
            guard let text = item.stringValue, text.hasPrefix("/") || text.hasPrefix("~/") else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an absolute or ~/ path"))
                return nil
            }
            return text.hasPrefix("~/") ? home + String(text.dropFirst(1)) : text
        }
        return settings
    }
}
