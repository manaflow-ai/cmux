/// Reads a ``GhosttyConfigLiveReloadSnapshot`` of the user's Ghostty config
/// files for ``GhosttyConfigLiveReloadCoordinator``.
///
/// Conformers perform file I/O. The requirement is `async` and nonisolated so
/// the coordinator, which runs on the main actor, awaits it without blocking
/// the main thread.
public protocol GhosttyConfigLiveReloadSnapshotReading: Sendable {
    /// Returns the current watch paths and file contents.
    func snapshot() async -> GhosttyConfigLiveReloadSnapshot
}
