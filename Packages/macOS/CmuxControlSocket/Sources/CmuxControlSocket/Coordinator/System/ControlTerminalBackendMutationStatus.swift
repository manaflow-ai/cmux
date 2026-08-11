/// Stable control-wire phases for a locally queued backend topology mutation.
public enum ControlTerminalBackendMutationStatus: String, Sendable, Equatable {
    /// The mutation waits for backend execution.
    case queued
    /// The backend is executing the mutation.
    case running
    /// The backend committed the mutation to canonical state.
    case committed
    /// The client observed the committed canonical revision.
    case projected
    /// The backend rejected the mutation or could not commit it.
    case failed
}
