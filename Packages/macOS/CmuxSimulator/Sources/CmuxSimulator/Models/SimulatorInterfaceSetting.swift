/// A Simulator appearance or accessibility setting exposed by `simctl ui`.
public enum SimulatorInterfaceSetting: Codable, Hashable, Sendable {
    /// Light or dark appearance.
    case appearance(Appearance)
    /// Increase Contrast accessibility state.
    case increaseContrast(Bool)
    /// Preferred Dynamic Type category.
    case contentSize(ContentSize)
    /// Relative Dynamic Type adjustment accepted by `simctl ui content_size`.
    case contentSizeAdjustment(ContentSizeAdjustment)
    /// iOS 26 Liquid Glass legibility style.
    case liquidGlass(LiquidGlass)
    /// Accessibility display color filter.
    case colorFilter(ColorFilter)
    /// Reduce Motion accessibility state.
    case reduceMotion(Bool)
    /// Button Shapes accessibility state.
    case buttonShapes(Bool)
    /// Reduce Transparency accessibility state.
    case reduceTransparency(Bool)
    /// VoiceOver accessibility state.
    case voiceOver(Bool)

    /// Whether this setting requires the bundled in-Simulator accessibility
    /// helper so the live private setter and notification are both applied.
    public var requiresSimulatorAccessibilityHelper: Bool {
        switch self {
        case .liquidGlass, .colorFilter, .reduceMotion, .buttonShapes,
             .reduceTransparency, .voiceOver:
            true
        default:
            false
        }
    }

    /// A supported appearance value.
    public enum Appearance: String, Codable, CaseIterable, Hashable, Sendable {
        /// Light system appearance.
        case light
        /// Dark system appearance.
        case dark
    }

    /// A Dynamic Type category accepted by `simctl ui content_size`.
    public enum ContentSize: String, Codable, CaseIterable, Hashable, Sendable {
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

    /// A relative Dynamic Type adjustment accepted by `simctl ui content_size`.
    public enum ContentSizeAdjustment: String, Codable, CaseIterable, Hashable, Sendable {
        /// Advance to the next larger Dynamic Type category.
        case increment
        /// Move to the next smaller Dynamic Type category.
        case decrement
    }

    /// A Liquid Glass legibility style.
    public enum LiquidGlass: String, Codable, CaseIterable, Hashable, Sendable {
        /// Clear glass.
        case clear
        /// Tinted glass with stronger contrast.
        case tinted
    }

    /// A system display color filter.
    public enum ColorFilter: String, Codable, CaseIterable, Hashable, Sendable {
        /// Disable color filtering.
        case none
        /// Grayscale.
        case grayscale
        /// Protanopia compensation.
        case redGreen = "red-green"
        /// Deuteranopia compensation.
        case greenRed = "green-red"
        /// Tritanopia compensation.
        case blueYellow = "blue-yellow"
    }
}
