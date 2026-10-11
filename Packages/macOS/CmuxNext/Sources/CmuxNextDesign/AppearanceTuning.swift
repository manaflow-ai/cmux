import Foundation

/// Live appearance adjustments applied to the shared window backdrop.
public nonisolated struct AppearanceTuning: Equatable, Sendable {
    /// Extra transparency from 0 (theme opacity) to 1 (clear glass).
    public var glassTransparency: Double
    /// Hue shift, where 0.5 leaves the theme color unchanged.
    public var hue: Double
    /// Saturation multiplier, where 1 leaves the theme color unchanged.
    public var saturation: Double

    /// The identity tuning used when the experimental controls are off.
    public nonisolated static let identity = AppearanceTuning(glassTransparency: 0, hue: 0.5, saturation: 1)

    /// Creates a clamped live tuning.
    public nonisolated init(glassTransparency: Double, hue: Double, saturation: Double) {
        self.glassTransparency = Self.clamp(glassTransparency, to: 0...1, fallback: 0)
        self.hue = Self.clamp(hue, to: 0...1, fallback: 0.5)
        self.saturation = Self.clamp(saturation, to: 0...2, fallback: 1)
    }

    private nonisolated static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Returns one slider value.
    public func value(for axis: AppearanceTuningAxis) -> Double {
        switch axis {
        case .glassTransparency: glassTransparency
        case .hue: hue
        case .saturation: saturation
        }
    }

    /// Returns a copy with one slider changed.
    public func setting(_ axis: AppearanceTuningAxis, to value: Double) -> AppearanceTuning {
        switch axis {
        case .glassTransparency: return AppearanceTuning(glassTransparency: value, hue: hue, saturation: saturation)
        case .hue: return AppearanceTuning(glassTransparency: glassTransparency, hue: value, saturation: saturation)
        case .saturation: return AppearanceTuning(glassTransparency: glassTransparency, hue: hue, saturation: value)
        }
    }
}
