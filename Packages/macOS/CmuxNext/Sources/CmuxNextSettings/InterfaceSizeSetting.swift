/// `appearance.interfaceScale` in cmux.json: one Labs multiplier for chrome
/// type, spacing and control heights. Absent means the familiar 100% layout.
public struct InterfaceSizeSetting: Sendable {
    public let configPath = ["appearance", "interfaceScale"]
    public let fallback = 1.0
    public let range: ClosedRange<Double> = 0.9...1.25
    public let step = 0.05
    public let values = [0.9, 1.0, 1.1, 1.25]
    public init() {}
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let number = value.doubleValue, number.isFinite else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.interfaceScale", message: "expected a scale from 0.9 to 1.25"))
            return fallback
        }
        if !range.contains(number) {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.interfaceScale", message: "expected a scale from 0.9 to 1.25; clamped"))
        }
        return min(max(number, range.lowerBound), range.upperBound)
    }
}
