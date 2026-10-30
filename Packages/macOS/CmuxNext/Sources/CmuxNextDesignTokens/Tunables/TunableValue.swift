public import Foundation

/// The stored value of one tunable (plans/cmux-next/debug-settings.md).
/// Defaults live in code; the store keeps only overrides, as these values.
public nonisolated enum TunableValue: Hashable, Sendable {
    case number(Double)
    case bool(Bool)
    /// The raw value of a `TunableChoice` case.
    case choice(String)
    case color(TunableColor)
    case spring(SpringParameters)

    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var choice: String? { if case .choice(let value) = self { value } else { nil } }
    public var color: TunableColor? { if case .color(let value) = self { value } else { nil } }
    public var spring: SpringParameters? { if case .spring(let value) = self { value } else { nil } }
}

/// What a number means, for the control and the formatted value.
public nonisolated enum TunableUnit: String, Sendable, Hashable, CaseIterable {
    case points
    case seconds
    /// 0...1, shown as a percentage.
    case fraction
    /// A plain factor (scales, damping).
    case multiplier
    case pointsPerSecond
    case count
}

/// The control a tunable gets, and how its values are clamped.
public nonisolated enum TunableKind: Sendable, Hashable {
    case number(range: ClosedRange<Double>, step: Double, unit: TunableUnit)
    case bool
    case choice([TunableChoiceOption])
    case color
    /// Response and damping, as `MotionSpring` tokens.
    case spring

    /// Limits for spring tunables (seconds, fraction).
    public static let springResponseRange: ClosedRange<Double> = 0.02...2
    public static let springDampingRange: ClosedRange<Double> = 0.1...1.5

    /// `value` made valid for this kind (numbers clamped to the range,
    /// springs to their limits), or nil when it has the wrong type or names
    /// no option.
    public func clamp(_ value: TunableValue) -> TunableValue? {
        switch (self, value) {
        case (.number(let range, _, _), .number(let number)):
            guard number.isFinite else { return nil }
            return .number(min(max(number, range.lowerBound), range.upperBound))
        case (.bool, .bool), (.color, .color):
            return value
        case (.choice(let options), .choice(let raw)):
            return options.contains { $0.value == raw } ? value : nil
        case (.spring, .spring(let spring)):
            guard spring.response.isFinite, spring.dampingFraction.isFinite else { return nil }
            let response = min(max(spring.response, Self.springResponseRange.lowerBound), Self.springResponseRange.upperBound)
            let damping = min(max(spring.dampingFraction, Self.springDampingRange.lowerBound), Self.springDampingRange.upperBound)
            return .spring(SpringParameters(response: response, dampingFraction: damping))
        default:
            return nil
        }
    }
}
