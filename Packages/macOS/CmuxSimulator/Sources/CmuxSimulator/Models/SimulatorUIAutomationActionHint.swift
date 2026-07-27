/// A compact suggested action derived from the current accessibility tree.
public struct SimulatorUIAutomationActionHint: Codable, Equatable, Sendable {
    /// The supported semantic action.
    public let action: SimulatorUIAutomationActionName
    /// The target's process-scoped element reference.
    public let elementRef: String
    /// The target label when one exists.
    public let label: String?

    /// Creates one suggested action.
    ///
    /// - Parameters:
    ///   - action: The supported semantic action.
    ///   - elementRef: The target element reference.
    ///   - label: The optional target label.
    public init(
        action: SimulatorUIAutomationActionName,
        elementRef: String,
        label: String?
    ) {
        self.action = action
        self.elementRef = elementRef
        self.label = label
    }
}
