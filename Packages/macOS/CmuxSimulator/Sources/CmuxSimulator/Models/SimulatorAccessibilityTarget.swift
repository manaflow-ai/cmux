/// A visible accessibility element and its normalized interaction point.
public struct SimulatorAccessibilityTarget: Equatable, Sendable {
    /// The matched accessibility element.
    public let node: SimulatorAccessibilityNode
    /// The center of the element, normalized to the foreground app viewport.
    public let point: SimulatorPoint

    /// Creates an accessibility interaction target.
    ///
    /// - Parameters:
    ///   - node: The matched accessibility element.
    ///   - point: The normalized center of the element.
    public init(node: SimulatorAccessibilityNode, point: SimulatorPoint) {
        self.node = node
        self.point = point
    }
}
