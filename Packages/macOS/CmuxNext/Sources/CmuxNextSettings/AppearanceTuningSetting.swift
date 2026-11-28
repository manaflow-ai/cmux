public import CmuxNextDesign

/// The persisted appearance tuner values in `cmux.json`.
///
/// Values are independent of the experimental UI gate: the gate decides
/// whether the controls are shown, while these keys describe the appearance
/// that the app applies when the controls are enabled.
public struct AppearanceTuningSetting: Sendable {
    public static let glassTransparencyPath = ["appearance", "glassTransparency"]
    public static let huePath = ["appearance", "hue"]
    public static let saturationPath = ["appearance", "saturation"]

    public static let glassTransparencyRange: ClosedRange<Double> = 0...1
    public static let hueRange: ClosedRange<Double> = 0...1
    public static let saturationRange: ClosedRange<Double> = 0...2

    public static let fallback = AppearanceTuning.identity

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
