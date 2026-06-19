/// Where a panel directory report came from, controlling whether the
/// restored-guarded-directory guard applies.
///
/// Lifted verbatim from the private `Workspace.PanelDirectoryUpdateSource`:
/// only ``liveReport`` reports run through
/// ``WorkspaceSurfaceMetadataModel/shouldIgnoreRestoredGuardedDirectoryReport(panelId:reportedDirectory:)``;
/// a ``restoredSnapshotMetadata`` report (the workspace replaying a saved
/// directory during restore) is always applied.
public enum PanelDirectoryUpdateSource: Sendable {
    /// A live cwd report from OSC 7 / shell integration.
    case liveReport
    /// A directory replayed from restored session-snapshot metadata.
    case restoredSnapshotMetadata
}
