/// The axis along which a mobile workspace split divides its children.
public enum MobileWorkspaceSplitOrientation: String, Codable, Equatable, Sendable {
    /// Children are arranged left to right.
    case horizontal
    /// Children are arranged top to bottom.
    case vertical
}
