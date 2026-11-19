public import CmuxNextDesign

/// `experiments.sidebarRowStyle` in cmux.json (`SidebarRowStyle`): the off-by-default sidebar
/// row restyle under Settings > Experimental. "off" (the default) draws today's rows. A missing
/// key is the default; a bad value is the default plus a diagnostic.
public nonisolated struct SidebarRowStyleSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarRowStyle {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let style = SidebarRowStyle(rawValue: text) else {
            let choices = SidebarRowStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return style
    }

    /// The style `snapshot` draws: the key, else ``fallback``.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> SidebarRowStyle {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `experiments.sidebarRowStyle` into `design`, writing only a change.
    static func applySidebarRowStyle(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let style = SidebarRowStyleSetting.effective(in: snapshot)
        if design.sidebarRowStyle != style { design.sidebarRowStyle = style }
    }
}
