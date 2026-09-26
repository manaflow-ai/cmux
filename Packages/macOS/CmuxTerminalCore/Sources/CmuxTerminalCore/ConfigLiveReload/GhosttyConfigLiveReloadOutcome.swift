/// What one ``GhosttyConfigLiveReloadCoordinator`` operation did.
public enum GhosttyConfigLiveReloadOutcome: Equatable, Sendable {
    /// A snapshot became the baseline (at start, or after a reload cmux
    /// started itself) and the watchers were armed on its paths.
    case baselineRecorded
    /// File contents changed, so the configuration was reloaded (including a
    /// change found by the re-read after re-arming the watchers).
    case reloaded
    /// A file event fired but no file contents changed, so nothing reloaded.
    case unchanged
}
