#if DEBUG
/// The outcome of the v1-only `simulate_file_drop` command's live read,
/// preserving the legacy body's distinct response lines (the witness performs
/// the `TabManager` availability guard, surface resolution, and hosted-view
/// drop synthesis; the coordinator's
/// ``ControlCommandCoordinator/debugSimulateFileDropV1(_:)`` owns the argument
/// parsing, the usage `ERROR` strings, and the response formatting).
public enum ControlDebugSimulateFileDropResolution: Sendable, Equatable {
    /// The controller's primary `TabManager` is unavailable (legacy
    /// `"ERROR: TabManager not available"`).
    case tabManagerUnavailable
    /// No terminal surface matched the target argument (legacy
    /// `"ERROR: Surface not found"`).
    case surfaceNotFound
    /// The hosted view synthesized the file drop (legacy `"OK"`).
    case dropped
    /// The hosted view declined the synthetic file drop (legacy
    /// `"ERROR: Failed to simulate drop"`).
    case dropFailed
}
#endif
