/// Pure snapshot-construction failures.
public enum SimulatorUIAutomationSnapshotError: Error, Equatable, Sendable {
    /// No native root exposed a usable foreground viewport.
    case viewportUnavailable
}
