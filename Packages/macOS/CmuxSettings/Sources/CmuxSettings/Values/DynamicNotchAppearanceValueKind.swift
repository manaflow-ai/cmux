/// The input contract for one Dynamic Notch appearance token.
public enum DynamicNotchAppearanceValueKind: Sendable, Equatable {
    /// A finite decimal number within the inclusive bounds.
    case number(minimum: Double, maximum: Double, step: Double)

    /// An integer within the inclusive bounds.
    case integer(minimum: Int, maximum: Int)

    /// A boolean.
    case boolean

    /// `system` or a `#RRGGBB` color.
    case color
}
