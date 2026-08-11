/// App-side lookup result for `terminal_backend.mutation_status`.
public enum ControlTerminalBackendMutationStatusResolution: Sendable, Equatable {
    /// This cmux process does not use the persistent terminal backend.
    case unavailable
    /// The backend is enabled, but local memory cannot prove whether this
    /// identifier committed. Callers must not retry the original mutation and
    /// must inspect the current canonical state through `system.tree`.
    case unknown
    /// The request is present with its current phase.
    case known(ControlTerminalBackendMutationStatus)
}
