/// The axis along which a workspace split divides its rectangle.
public enum MobileWorkspaceLayoutOrientation: String, Codable, Equatable, Sendable {
    /// Places the split's children side by side.
    case horizontal

    /// Stacks the split's children vertically.
    case vertical
}
