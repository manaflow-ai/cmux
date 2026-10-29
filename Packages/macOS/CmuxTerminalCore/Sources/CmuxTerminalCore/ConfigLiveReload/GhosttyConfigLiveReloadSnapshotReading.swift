/// Reads a ``GhosttyConfigLiveReloadSnapshot`` of the user's Ghostty config
/// files for ``GhosttyConfigLiveReloadCoordinator``.
///
/// Conformers perform synchronous file I/O and must be safe to call from any
/// thread. The coordinator reads off the main thread for file events, and on
/// the main thread only at the moment Ghostty itself reads the same files
/// (``GhosttyConfigLiveReloadCoordinator/noteConfigurationFilesWillLoad()``),
/// so the snapshot records exactly what that load sees.
public protocol GhosttyConfigLiveReloadSnapshotReading: Sendable {
    /// Returns the current watch paths and file contents.
    func snapshot() -> GhosttyConfigLiveReloadSnapshot
}
