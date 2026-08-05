/// The axis along which a pane split divides its available rectangle.
public enum MobilePaneSplitOrientation: Sendable, Equatable {
    /// Places the first and second children side by side.
    case horizontal
    /// Stacks the first child above the second child in unit-space order.
    case vertical
}
