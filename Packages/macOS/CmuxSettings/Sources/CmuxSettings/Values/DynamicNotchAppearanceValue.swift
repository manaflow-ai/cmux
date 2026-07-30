/// A validated value for one Dynamic Notch appearance token.
public enum DynamicNotchAppearanceValue: Sendable, Equatable, Hashable {
    /// A decimal layout or behavior value.
    case number(Double)

    /// An integral line limit.
    case integer(Int)

    /// A boolean behavior value.
    case boolean(Bool)

    /// A semantic or explicit color.
    case color(DynamicNotchAppearanceColor)
}
