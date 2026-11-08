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
    public typealias Appearance = SimulatorInterfaceAppearance
    /// A Dynamic Type category accepted by `simctl ui content_size`.
    public typealias ContentSize = SimulatorInterfaceContentSize
    /// A relative Dynamic Type adjustment accepted by `simctl ui content_size`.
    public typealias ContentSizeAdjustment = SimulatorInterfaceContentSizeAdjustment
    /// A Liquid Glass legibility style.
    public typealias LiquidGlass = SimulatorInterfaceLiquidGlass
    /// A system display color filter.
    public typealias ColorFilter = SimulatorInterfaceColorFilter
}
