import CmuxSimulator

/// One semantic touch-down target retained across snapshot replacement.
public struct SimulatorUIAutomationHeldTouch: Equatable, Sendable {
    /// The snapshot-scoped reference that began the touch.
    public let elementRef: String
    /// The normalized display point where the touch began.
    public let point: SimulatorPoint
    /// The display metadata used to translate the retained point.
    public let display: SimulatorDisplayMetadata?
}
