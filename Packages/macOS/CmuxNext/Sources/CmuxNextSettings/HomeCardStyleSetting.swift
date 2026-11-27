public import CmuxNextDesign

/// `appearance.homeCardStyle` in cmux-next.json (Settings > Appearance, Home Cards): "standard" (the default),
/// "flat", "raised" or "glass" (`HomeCardStyle`), for the cards on Home and the New Tab page. A missing key is the
/// default; a bad value is the default plus a diagnostic. A theme file can set it like any other `appearance.*` key.
/// Its path, default and choices are generated from schemas/settings/source/appearance.json.
public nonisolated struct HomeCardStyleSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> HomeCardStyle {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let style = HomeCardStyle(rawValue: text) else {
            let choices = HomeCardStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return style
    }

    /// The card style `snapshot` asks for.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> HomeCardStyle {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `appearance.homeCardStyle` into `design`, writing only a change.
    static func applyHomeCardStyle(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let style = HomeCardStyleSetting.effective(in: snapshot)
        if design.homeCardStyle != style { design.homeCardStyle = style }
    }
}
