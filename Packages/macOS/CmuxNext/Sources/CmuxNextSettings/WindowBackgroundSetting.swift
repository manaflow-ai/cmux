public import CmuxNextDesign

/// `appearance.backgroundOpacity` (0...1) and `appearance.backgroundBlur`
/// (`frosted`, `glass`, `glass-clear` or `none` for no blur) in cmux.json: cmux's own
/// window background over Ghostty's `background-opacity` and
/// `background-blur`. Unset keys keep Ghostty's values, so a window stays
/// opaque until one of the two configs asks for translucency.
public nonisolated enum WindowBackgroundSetting {
    /// `appearance.backgroundOpacity`: the window's opacity, 0...1.
    public static let opacityPath = ["appearance", "backgroundOpacity"]
    /// `appearance.backgroundBlur`: the window material (`frosted`,
    /// `glass`, `glass-clear`, or `none` for no blur).
    public static let materialPath = ["appearance", "backgroundBlur"]
    /// The opacity range, as Ghostty's `background-opacity`.
    public static let opacityRange: ClosedRange<Double> = 0...1

    /// A missing key keeps Ghostty's value with no diagnostic; a bad value
    /// keeps it too, plus a diagnostic at the key.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> WindowBackgroundOverride {
        var opacity: Double?
        if let value = root.value(at: opacityPath) {
            if let number = value.doubleValue, opacityRange.contains(number) {
                opacity = number
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backgroundOpacity",
                                                      message: "expected a number from 0 to 1, such as 0.85"))
            }
        }
        var material: WindowMaterialChoice?
        if let value = root.value(at: materialPath) {
            if let text = value.stringValue, let choice = WindowMaterialChoice(rawValue: text) {
                material = choice
            } else {
                let choices = WindowMaterialChoice.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backgroundBlur",
                                                      message: "expected one of \(choices)"))
            }
        }
        return WindowBackgroundOverride(opacity: opacity, material: material)
    }
}
