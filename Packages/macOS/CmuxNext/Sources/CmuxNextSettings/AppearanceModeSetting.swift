public import AppKit
public import CmuxNextActions

/// `appearance.mode` in cmux.json (`AppearanceMode`): the app's own light or
/// dark appearance. A missing key is `system` (follow macOS, the default); a
/// bad value is that plus a diagnostic. The app applies it to `NSApp.appearance`
/// (`AppearanceModeSetting+App.swift`), which the chrome and every light/dark theme pair follow.
public nonisolated struct AppearanceModeSetting: Sendable {
    // The path and default are generated from schemas/settings/source/appearance.json.

    public init() {}

    /// The palette and CLI action that switches to `mode`
    /// (`cmux settings appearance-light`, `-dark`, `-system`).
    public static func actionID(_ mode: AppearanceMode) -> String { "appearance.mode.\(mode.rawValue)" }

    /// The file value for `mode`: the default removes the key.
    public static func fileValue(_ mode: AppearanceMode) -> JSONValue? {
        mode == fallback ? nil : .string(mode.rawValue)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AppearanceMode {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let mode = AppearanceMode(rawValue: text) else {
            let choices = AppearanceMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return mode
    }
}

extension AppearanceModeSetting {
    /// Binds `appearance.mode.system`, `.light` and `.dark`, each previewing
    /// its appearance on `app` while its palette row is highlighted.
    @MainActor public static func bindActions(into registry: ActionRegistry, save: @escaping SettingChoiceActions.Save,
                                              app: NSApplication = .shared) {
        SettingChoiceActions.bind(AppearanceMode.allCases, into: registry, id: actionID, path: configPath, fileValue: fileValue,
                                  save: save, current: { current(of: app) }) { apply($0, to: app) }
    }
}
