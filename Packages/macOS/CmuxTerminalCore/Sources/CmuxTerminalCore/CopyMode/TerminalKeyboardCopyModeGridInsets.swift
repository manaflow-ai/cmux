/// The top-left inset of Ghostty's rendered cell grid in AppKit points.
public struct TerminalKeyboardCopyModeGridInsets: Equatable, Sendable {
    /// Horizontal distance from the host view's left edge.
    public let left: Double
    /// Vertical distance from the host view's top edge.
    public let top: Double

    /// Creates terminal grid insets in AppKit points.
    public init(left: Double, top: Double) {
        self.left = left
        self.top = top
    }
}
