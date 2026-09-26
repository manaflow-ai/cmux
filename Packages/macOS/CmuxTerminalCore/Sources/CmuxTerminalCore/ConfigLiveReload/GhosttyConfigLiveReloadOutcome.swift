/// What one ``GhosttyConfigLiveReloadCoordinator`` operation did.
public enum GhosttyConfigLiveReloadOutcome: Equatable, Sendable {
    /// A snapshot became the baseline (at start, or after a reload cmux
    /// started itself) and the watchers were armed on its paths.
    case baselineRecorded
    /// A baseline refresh after an external reload was dropped because a
    /// file change is still pending evaluation.
    case baselineSkippedForPendingChange
    /// File contents changed, so the configuration was reloaded.
    case reloaded
    /// A file event fired but no file contents changed, so nothing reloaded.
    case unchanged
}
