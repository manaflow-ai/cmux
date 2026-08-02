/// Private lookup metadata retained with one public runtime element.
public struct SimulatorUIAutomationElementRecord: Equatable, Sendable {
    /// The public compact element.
    public let element: SimulatorUIAutomationElement
    /// The source native accessibility node.
    public let node: SimulatorAccessibilityNode
    /// The deterministic tree path used for diagnostics.
    public let path: String
    /// The normalized activation point.
    public let activationPoint: SimulatorPoint
    /// The foreground viewport in Simulator points.
    public let viewport: SimulatorRect
    /// The element frame clipped to the viewport.
    public let swipeFrame: SimulatorRect?

    /// Creates one compact element and its process-local lookup metadata.
    ///
    /// - Parameters:
    ///   - element: The public compact element.
    ///   - node: The source accessibility node.
    ///   - path: The deterministic source-tree path.
    ///   - activationPoint: The normalized activation point.
    ///   - viewport: The foreground viewport.
    ///   - swipeFrame: The element frame clipped to the viewport.
    public init(
        element: SimulatorUIAutomationElement,
        node: SimulatorAccessibilityNode,
        path: String,
        activationPoint: SimulatorPoint,
        viewport: SimulatorRect,
        swipeFrame: SimulatorRect?
    ) {
        self.element = element
        self.node = node
        self.path = path
        self.activationPoint = activationPoint
        self.viewport = viewport
        self.swipeFrame = swipeFrame
    }
}
