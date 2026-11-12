public import CmuxNextDesign
import CoreGraphics

/// `appearance.titleAreaContrast` in cmux-next.json (Settings > Appearance > Panes, Title Area Contrast): how
/// strongly the chrome around the content (the titlebar, the tab row and the sidebar) is shaded, as a share
/// of the theme's shade (`Metrics.mainPaneChromeShade(isDark:)`). Leo, 2026-11-11: "the contrast, I guess
/// it's fine, but I feel like it may be too intense for some people, so it needs to be adjustable."
/// 1, the default, is the shade as it was. A missing key is the default; a value that is no number is the
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
