public import CmuxNextDesign
import CoreGraphics

/// `appearance.titleAreaContrast` in cmux-next.json (Settings > Appearance > Panes, Title Area Contrast): how
/// strongly the chrome around the content (the titlebar, the tab row and the sidebar) is shaded, as a share
/// of the theme's shade (`Metrics.titleAreaShadeScale`). Leo, 2026-11-11: "the contrast, I guess
/// it's fine, but I feel like it may be too intense for some people, so it needs to be adjustable."
/// 1 is the default: Subtle Tone's shade, and a picked chrome style's own shade. A missing key is the default; a value that is no number is the
/// default plus a diagnostic; a number outside the range is clamped, with a diagnostic. A theme file can set
/// it like any other `appearance.*` key. Its path, default and range are generated from
/// schemas/settings/source/appearance.json.
public nonisolated struct TitleAreaContrastSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: configPath) else { return fallback }
        let path = configPath.joined(separator: "."), expected = "expected a number from \(range.lowerBound) to \(range.upperBound)"
        guard let number = value.doubleValue, number.isFinite else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: expected))
            return fallback
        }
        if !range.contains(number) { diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: expected + "; clamped")) }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    /// The contrast `snapshot` asks for.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> Double {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `appearance.titleAreaContrast` into `design`, writing only a change.
    static func applyTitleAreaContrast(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let contrast = CGFloat(TitleAreaContrastSetting.effective(in: snapshot))
        if design.titleAreaContrast != contrast { design.titleAreaContrast = contrast }
    }
}

/// `appearance.titleAreaTone` in cmux-next.json (Settings > Appearance > Panes, Title Area): "oneColor" (the
/// default) or "subtleTone" (`TitleAreaTone`). A missing key is the default; a bad value is the default plus a
/// diagnostic. Its path, default and choices are generated from schemas/settings/source/appearance.json.
public nonisolated struct TitleAreaToneSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> TitleAreaTone {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let tone = TitleAreaTone(rawValue: text) else {
            let choices = TitleAreaTone.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return tone
    }

    /// The tone `snapshot` asks for.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> TitleAreaTone {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies `appearance.titleAreaTone` into `design`, writing only a change.
    static func applyTitleAreaTone(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let tone = TitleAreaToneSetting.effective(in: snapshot)
        if design.titleAreaTone != tone { design.titleAreaTone = tone }
    }
}
