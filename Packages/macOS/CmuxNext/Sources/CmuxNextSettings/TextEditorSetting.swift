public import Foundation

/// `files.textEditor`: the app a path's Open in Text Editor uses, as an app name ("Zed"), a
/// bundle ID (`dev.zed.Zed`) or a `.app` path. Empty (the default) means the system's app for
/// source code. The App resolves it when a menu opens.
public nonisolated struct TextEditorSetting: Sendable, Hashable {
    public static let configPath = ["files", "textEditor"]
    public var application: String

    public init(application: String = "") {
        self.application = application
    }

    static func parse(_ root: JSONValue) -> (TextEditorSetting, [SettingsDiagnostic]) {
        guard let value = root.value(at: configPath) else { return (TextEditorSetting(), []) }
        guard let text = value.stringValue else {
            return (TextEditorSetting(), [SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."), message: "expected an app name, bundle ID or app path")])
        }
        return (TextEditorSetting(application: text.trimmingCharacters(in: .whitespacesAndNewlines)), [])
    }
}
