public import CmuxNextDesign

/// The persisted appearance tuner values in `cmux.json`.
///
/// Values are independent of the experimental gate
/// (`appearance.experimentalControls`): the gate decides whether the app
/// applies them to the window tint, while these keys hold the values.
public struct AppearanceTuningSetting: Sendable {
    // Each axis's path, range and default are generated from schemas/settings/source/appearance.json.

    /// The values when no axis is set.
    public static let fallback = AppearanceTuning(glassTransparency: glassTransparencyDefault, hue: hueDefault,
                                                  saturation: saturationDefault)

    public init() {}

    /// Parses each axis independently. An absent axis uses its identity value;
    /// a malformed or out-of-range axis keeps that value and reports a
    /// diagnostic at the axis key.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AppearanceTuning {
        let transparency = number(root, at: glassTransparencyPath, range: glassTransparencyRange,
                                  fallback: fallback.glassTransparency, diagnostics: &diagnostics,
                                  example: "0.35")
        let hue = number(root, at: huePath, range: hueRange,
                         fallback: fallback.hue, diagnostics: &diagnostics,
                         example: "0.5")
        let saturation = number(root, at: saturationPath, range: saturationRange,
                                fallback: fallback.saturation, diagnostics: &diagnostics,
                                example: "1.25")
        return AppearanceTuning(glassTransparency: transparency, hue: hue, saturation: saturation)
    }

    private static func number(_ root: JSONValue, at path: [String], range: ClosedRange<Double>,
                               fallback: Double, diagnostics: inout [SettingsDiagnostic], example: String) -> Double {
        guard let value = root.value(at: path) else { return fallback }
        guard let number = value.doubleValue, number.isFinite, range.contains(number) else {
            diagnostics.append(SettingsDiagnostic(
                kind: .invalidValue,
                path: path.joined(separator: "."),
                message: "expected a number from \(range.lowerBound) to \(range.upperBound), such as \(example)"
            ))
            return fallback
        }
        return number
    }
}
