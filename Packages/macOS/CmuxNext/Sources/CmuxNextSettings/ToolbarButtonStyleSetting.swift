public import CmuxNextDesign

/// `appearance.toolbarButtonStyle` in cmux-next.json (Settings > Appearance, Top Right Buttons): "standard" (the
/// default, today's look), "plain", "grouped" or "glass" (`ToolbarButtonStyle`). A missing key is the default; a bad
/// value is the default plus a diagnostic. A theme file can set it like any other `appearance.*` key, and a save of
/// that file applies it at once. Its path, default and choices are generated from
/// schemas/settings/source/appearance.json.
public nonisolated struct ToolbarButtonStyleSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> ToolbarButtonStyle {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let style = ToolbarButtonStyle(rawValue: text) else {
            let choices = ToolbarButtonStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return style
    }

    /// The style `snapshot` asks for.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> ToolbarButtonStyle {
        var ignored: [SettingsDiagnostic] = [] // the snapshot's own parse reports a bad value
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `appearance.toolbarButtonStyle` into `design`, writing only a change.
    static func applyToolbarButtonStyle(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let style = ToolbarButtonStyleSetting.effective(in: snapshot)
        if design.toolbarButtonStyle != style { design.toolbarButtonStyle = style }
    }
}
