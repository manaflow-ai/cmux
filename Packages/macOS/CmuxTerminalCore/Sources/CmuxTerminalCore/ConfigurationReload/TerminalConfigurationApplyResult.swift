/// The result of applying one configuration snapshot to one terminal surface.
public enum TerminalConfigurationApplyResult: Sendable {
    /// The surface accepted the snapshot and needs no further work.
    case complete

    /// The surface could not finish a transient reconciliation step and should
    /// be retried in a later bounded turn.
    case retry
}
