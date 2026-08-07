/// A lifecycle change consumed by the AppKit approval coordinator.
public enum SudoBrokerEvent: Sendable, Equatable {
    /// A request became available for presentation.
    case discovered(SudoPendingRequest)

    /// A request advanced after an explicit approval.
    case phaseChanged(id: String, phase: SudoRequestPhase)

    /// A request reached a terminal result.
    case settled(SudoResult)
}
