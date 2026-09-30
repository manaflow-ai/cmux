public nonisolated struct SettingChoice: Sendable, Hashable {
    public let value: String
    public let title: String

    public init(_ value: String, _ title: String) {
        self.value = value
        self.title = title
    }
}

public nonisolated struct SettingNumber: Sendable, Hashable {
    /// `fraction` is a proportion (0.5) shown as a percentage.
    public enum Unit: Sendable, Hashable { case points, seconds, minutes, count, fraction }

    public let range: ClosedRange<Double>
    public let step: Double
    public let unit: Unit
    /// Where the control sits while the key is absent and the default is
    /// derived (`defaultValue` nil).
    public let placeholder: Double

    public init(_ range: ClosedRange<Double>, step: Double, unit: Unit, placeholder: Double? = nil) {
        self.range = range
        self.step = step
        self.unit = unit
        self.placeholder = placeholder ?? range.lowerBound
    }
}
