/// Localized validation messages for tab color actions.
///
/// The app supplies these values so `String(localized:)` resolves against the
/// app bundle instead of the package bundle.
public struct ControlTabActionStrings: Sendable, Equatable {
    /// The message returned when `set_color` has no usable color.
    public let missingColor: String
    /// The message returned when `set_color` cannot resolve the supplied color.
    public let invalidColor: String

    /// Creates the localized tab-action message bundle.
    public init(missingColor: String, invalidColor: String) {
        self.missingColor = missingColor
        self.invalidColor = invalidColor
    }
}
