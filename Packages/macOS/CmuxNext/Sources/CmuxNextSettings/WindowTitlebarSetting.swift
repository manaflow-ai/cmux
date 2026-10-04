public import CmuxNextDesign

/// `window.titlebar` in cmux.json: "minimal" (default: no titlebar strip,
/// the top row's empty space moves the window) or "standard" (a titlebar
/// strip with the workspace name).
public nonisolated enum WindowTitlebarSetting {
    public static let configPath = ["window", "titlebar"]
    public static let fallback: TitlebarStyle = .minimal

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (TitlebarStyle, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let style = TitlebarStyle(rawValue: text) else {
            let choices = TitlebarStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "window.titlebar", message: "expected one of \(choices)"))
        }
        return (style, nil)
    }
}

/// `window.titlebarButtons` in cmux-next.json (R83): "hover" (default) or
/// "always".
public nonisolated enum TitlebarButtonsSetting {
    public static let configPath = ["window", "titlebarButtons"]
    public static let fallback: TitlebarButtonsMode = .hover

    static func parse(_ root: JSONValue) -> (TitlebarButtonsMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = TitlebarButtonsMode(rawValue: text) else {
            let choices = TitlebarButtonsMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "window.titlebarButtons", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}

/// `tabs.plusButton` in cmux-next.json (R120): "hover" (default) or "always".
public nonisolated enum PlusButtonSetting {
    public static let configPath = ["tabs", "plusButton"]
    public static let fallback: PlusButtonMode = .hover

    static func parse(_ root: JSONValue) -> (PlusButtonMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = PlusButtonMode(rawValue: text) else {
            let choices = PlusButtonMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.plusButton", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}
