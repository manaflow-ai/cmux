/// Live values read through the in-Simulator accessibility settings helper.
public struct SimulatorInterfaceStatus: Codable, Equatable, Sendable {
    /// Public `simctl ui` appearance readback, or `nil` when unsupported.
    public let appearance: SimulatorInterfaceSetting.Appearance?
    /// Public `simctl ui` Dynamic Type readback, or `nil` when unsupported.
    public let contentSize: SimulatorInterfaceSetting.ContentSize?
    /// Public `simctl ui` Increase Contrast readback, or `nil` when unsupported.
    public let increaseContrast: Bool?
    /// iOS 26 Liquid Glass legibility style.
    public let liquidGlass: SimulatorInterfaceSetting.LiquidGlass
    /// Active system color filter.
    public let colorFilter: SimulatorInterfaceSetting.ColorFilter
    /// Whether Reduce Motion is enabled.
    public let reduceMotion: Bool
    /// Whether Button Shapes is enabled.
    public let buttonShapes: Bool
    /// Whether Reduce Transparency is enabled.
    public let reduceTransparency: Bool
    /// Whether VoiceOver is enabled.
    public let voiceOver: Bool

    /// Creates a live interface-settings snapshot.
    public init(
        appearance: SimulatorInterfaceSetting.Appearance? = nil,
        contentSize: SimulatorInterfaceSetting.ContentSize? = nil,
        increaseContrast: Bool? = nil,
        liquidGlass: SimulatorInterfaceSetting.LiquidGlass,
        colorFilter: SimulatorInterfaceSetting.ColorFilter,
        reduceMotion: Bool,
        buttonShapes: Bool,
        reduceTransparency: Bool,
        voiceOver: Bool
    ) {
        self.appearance = appearance
        self.contentSize = contentSize
        self.increaseContrast = increaseContrast
        self.liquidGlass = liquidGlass
        self.colorFilter = colorFilter
        self.reduceMotion = reduceMotion
        self.buttonShapes = buttonShapes
        self.reduceTransparency = reduceTransparency
        self.voiceOver = voiceOver
    }
}
