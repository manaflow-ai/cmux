/// An accessibility field clipped by the native worker's field-size limit.
public enum SimulatorUIAutomationTruncatedField: String, Codable, CaseIterable, Sendable {
    /// The native accessibility identifier was clipped.
    case identifier
    /// The native accessibility label was clipped.
    case label
    /// The native accessibility value was clipped.
    case value
}
