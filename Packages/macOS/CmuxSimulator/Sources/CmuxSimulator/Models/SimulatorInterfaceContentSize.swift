/// A Dynamic Type category accepted by `simctl ui content_size`.
public enum SimulatorInterfaceContentSize: String, Codable, CaseIterable, Hashable, Sendable {
    /// Extra-small text.
    case extraSmall = "extra-small"
    /// Small text.
    case small
    /// Medium text.
    case medium
    /// Large text.
    case large
    /// Extra-large text.
    case extraLarge = "extra-large"
    /// Extra-extra-large text.
    case extraExtraLarge = "extra-extra-large"
    /// Extra-extra-extra-large text.
    case extraExtraExtraLarge = "extra-extra-extra-large"
    /// Accessibility medium text.
    case accessibilityMedium = "accessibility-medium"
    /// Accessibility large text.
    case accessibilityLarge = "accessibility-large"
    /// Accessibility extra-large text.
    case accessibilityExtraLarge = "accessibility-extra-large"
    /// Accessibility extra-extra-large text.
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    /// Accessibility extra-extra-extra-large text.
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"
}
