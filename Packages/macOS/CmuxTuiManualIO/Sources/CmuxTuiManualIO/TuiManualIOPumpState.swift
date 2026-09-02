/// Describes the lifecycle state shown by a manual-IO terminal pane.
public enum TuiManualIOPumpState: Equatable, Sendable {
    /// The first relay attach is in progress.
    case connecting
    /// Relay bytes are flowing.
    case live
    /// The relay was lost and another attach is scheduled.
    case reconnecting(attempt: Int)
    /// The daemon reports that the terminal ended.
    case ended
    /// Automatic retries stopped after repeated unexplained failures.
    case failed
}
