public import CoreGraphics

/// The horizontal content insets applied to a terminal to protect a hardware
/// feature (e.g. the landscape camera area).
public struct MobileTerminalContentInsets: Equatable, Sendable {
    /// A zero-inset value.
    public static let zero = MobileTerminalContentInsets(leading: 0, trailing: 0)

    /// The leading-edge inset, in points.
    public var leading: CGFloat
    /// The trailing-edge inset, in points.
    public var trailing: CGFloat

    /// Creates a content-inset value.
    /// - Parameters:
    ///   - leading: The leading-edge inset, in points.
    ///   - trailing: The trailing-edge inset, in points.
    public init(leading: CGFloat, trailing: CGFloat) {
        self.leading = leading
        self.trailing = trailing
    }
}
