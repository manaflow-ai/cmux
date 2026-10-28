public import CmuxNextAppearance
import CoreGraphics

/// `appearance.metrics.chromeFontSize` in cmux.json: the legacy interface size.
public struct InterfaceSizeSetting: Sendable {
    public let metricName = "chromeFontSize"
    public var configPath: [String] { ["appearance", "metrics", metricName] }
    public let range: ClosedRange<Double> = 10...16
    public init() {}
}

/// `appearance.interfaceScale` in cmux.json: one opt-in multiplier for chrome (Debug Settings `chrome.interfaceSize`).
public struct InterfaceScaleSetting: Sendable {
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
        if !range.contains(number) { diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.interfaceScale", message: "expected a scale from 0.9 to 1.25; clamped")) }
        return min(max(number, range.lowerBound), range.upperBound)
    }
}

/// The palette's Interface Size step and reset: `appearance.interfaceScale` while the Debug
/// Settings toggle `chrome.interfaceSize` is on, else the familiar `chromeFontSize` in points.
@MainActor
extension DesignSettings {
    /// The setting an Interface Size step or reset writes.
    public var interfaceSizePath: [String] {
        interfaceScaleEnabled ? InterfaceScaleSetting().configPath : InterfaceSizeSetting().configPath
    }

    /// Steps the interface size by `delta` (a scale step, or a point) and returns the value to save.
    public func stepInterfaceSize(by delta: Int) -> Double {
        guard interfaceScaleEnabled else {
            let points = overrides[.chromeFontSize] ?? densityTokens.bodySize
            setOverride(.chromeFontSize, points + CGFloat(delta))
            return Double(overrides[.chromeFontSize] ?? points)
        }
        let values = InterfaceScaleSetting().values, current = Double(interfaceScale)
        let index = values.enumerated().min(by: { abs($0.element - current) < abs($1.element - current) })?.offset ?? 1
        let next = values[min(max(index + delta, 0), values.count - 1)]
        interfaceScale = CGFloat(next)
        return next
    }

    /// Puts the chosen interface size back to its default (the caller removes the key).
    public func resetInterfaceSize() {
        if interfaceScaleEnabled { interfaceScale = CGFloat(InterfaceScaleSetting().fallback) } else { setOverride(.chromeFontSize, nil) }
    }
}
