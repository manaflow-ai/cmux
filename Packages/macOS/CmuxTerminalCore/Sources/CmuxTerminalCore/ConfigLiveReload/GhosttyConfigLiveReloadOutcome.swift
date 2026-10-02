/// What one ``GhosttyConfigLiveReloadCoordinator`` operation did.
public enum GhosttyConfigLiveReloadOutcome: Equatable, Sendable {
    /// The watchers were armed on the current paths: at start, where the
    /// snapshot also became the baseline, or after a reload finished.
    case baselineRecorded
    /// File contents changed, so the configuration was reloaded (including a
    /// change found by the re-read after re-arming the watchers).
    case reloaded
    /// A file event fired but no file contents changed, so nothing reloaded.
    case unchanged
}
