/// Admission failures for pane-scoped Simulator UI transactions.
public enum SimulatorUIAutomationTransactionError: Error, Equatable, Sendable {
    /// The pane already owns one active and eight queued transactions.
    case busy
}
