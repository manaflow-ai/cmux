/// A compact, public runtime UI element.
public struct SimulatorUIAutomationElement: Codable, Equatable, Sendable {
    /// The process-scoped reference valid for the snapshot lifetime.
    public let ref: String
    /// The normalized semantic role.
    public let role: SimulatorUIAutomationRole?
    /// The native accessibility label.
    public let label: String?
    /// The native accessibility value.
    public let value: String?
    /// The native accessibility identifier.
    public let identifier: String?
    /// The element frame in Simulator points.
    public let frame: SimulatorRect
    /// The element's normalized state.
    public let state: SimulatorUIAutomationElementState
    /// The semantic actions safe to perform on this element.
    public let actions: [SimulatorUIAutomationActionName]

    /// Creates one compact runtime element.
    ///
    /// - Parameters:
    ///   - ref: The process-scoped reference.
    ///   - role: The normalized role.
    ///   - label: The accessibility label.
    ///   - value: The accessibility value.
    ///   - identifier: The accessibility identifier.
    ///   - frame: The frame in Simulator points.
    ///   - state: The normalized element state.
    ///   - actions: The safe semantic actions.
    public init(
        ref: String,
        role: SimulatorUIAutomationRole?,
        label: String?,
        value: String?,
        identifier: String?,
        frame: SimulatorRect,
        state: SimulatorUIAutomationElementState,
        actions: [SimulatorUIAutomationActionName]
    ) {
        self.ref = ref
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.state = state
        self.actions = actions
    }
}
