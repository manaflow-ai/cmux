/// The backend-only host connection phase.
public enum BackendOnlyHostPhase: Equatable {
    /// The host is connecting to the backend.
    case connecting

    /// The host has a live canonical session.
    case ready

    /// The backend is unavailable.
    case unavailable
}
