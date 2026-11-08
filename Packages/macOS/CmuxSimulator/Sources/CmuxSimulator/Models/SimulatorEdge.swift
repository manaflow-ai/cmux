/// A system-gesture edge recognized by the Simulator HID transport.
public enum SimulatorEdge: UInt32, Codable, Sendable {
    /// A regular touch with no system-edge classification.
    case none = 0
    /// The display's leading edge.
    case left = 1
    /// The display's top edge.
    case top = 2
    /// The home-indicator edge.
    case bottom = 3
    /// The display's trailing edge.
    case right = 4
}
