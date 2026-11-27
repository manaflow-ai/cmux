public import CmuxNextDesign

/// `appearance.twoTone` in cmux-next.json (Settings > Appearance > Panes, Two-Tone): "off" (the default), "auto" or
/// a pairing (`TwoTone`), under any chrome style and any theme, and a theme-file key like any other `appearance.*`
/// one. It rides on the surface backgrounds (`SurfaceBackgrounds.twoTone`), so every surface owner paints it through
/// the one resolver and an explicit `appearance.surfaces.<surface>.color` wins. A missing key is the default; a bad
/// value is the default plus a diagnostic. Its path, default and choices are generated from
/// schemas/settings/source/appearance.json; the colors are Rust's (cmux-config `theme_file::two_tone`).
public nonisolated struct TwoToneSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> TwoTone {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let tone = TwoTone(rawValue: text) else {
            let choices = TwoTone.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return tone
    }
}
