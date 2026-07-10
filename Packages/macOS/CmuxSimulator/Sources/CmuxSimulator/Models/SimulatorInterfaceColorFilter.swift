/// A Simulator display color filter.
public enum SimulatorInterfaceColorFilter: String, Codable, CaseIterable, Hashable, Sendable {
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
