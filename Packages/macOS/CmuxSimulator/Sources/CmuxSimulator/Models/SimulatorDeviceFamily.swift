/// A family of Apple Simulator devices supported by the native pane.
public enum SimulatorDeviceFamily: String, Codable, CaseIterable, Sendable {
    /// An iPhone Simulator.
    case iPhone
    /// An iPad Simulator.
    case iPad
    /// An Apple Watch Simulator.
    case watch
    /// A visionOS Simulator.
    case vision
    /// A tvOS Simulator.
    case television
    /// A runtime whose device family is not recognized by this Xcode version.
    case unknown
}
