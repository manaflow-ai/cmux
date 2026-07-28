enum PanelPinMutationOutcome: Equatable {
    /// The requested pin state is durable without further work.
    case completed
    /// The requested pin state is optimistic while a remote mirror verifies it.
    case queued
    /// The target rejected the requested pin state.
    case failed
}
