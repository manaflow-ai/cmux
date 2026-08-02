/// Exact selector fields accepted by Simulator UI waits.
public struct SimulatorUIAutomationSelector: Equatable, Sendable {
    /// The element reference that produced this stable selector.
    public let sourceElementRef: String?
    /// An exact native accessibility identifier.
    public let identifier: String?
    /// An exact native accessibility label.
    public let label: String?
    /// An exact normalized semantic role.
    public let role: SimulatorUIAutomationRole?
    /// An exact native accessibility value.
    public let value: String?

    /// Creates an exact semantic selector.
    ///
    /// - Parameters:
    ///   - sourceElementRef: The optional source element reference.
    ///   - identifier: An exact accessibility identifier.
    ///   - label: An exact accessibility label.
    ///   - role: An exact normalized role.
    ///   - value: An exact accessibility value.
    public init(
        sourceElementRef: String? = nil,
        identifier: String? = nil,
        label: String? = nil,
        role: SimulatorUIAutomationRole? = nil,
        value: String? = nil
    ) {
        self.sourceElementRef = sourceElementRef
        self.identifier = identifier
        self.label = label
        self.role = role
        self.value = value
    }

    /// Whether the selector contains at least one exact semantic field.
    public var hasFields: Bool {
        identifier != nil || label != nil || role != nil || value != nil
    }
}
