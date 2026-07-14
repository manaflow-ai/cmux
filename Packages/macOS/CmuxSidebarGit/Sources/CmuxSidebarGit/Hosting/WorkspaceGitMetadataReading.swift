public import CmuxGit

/// Reads a directory's on-disk git metadata (branch, dirty state, index and
/// head signatures) off the main actor. Injected into
/// ``SidebarGitMetadataService`` so tests can supply a fake reader without
/// touching the filesystem.
public protocol WorkspaceGitMetadataReading: Sendable {
    /// Returns the git metadata for `directory`.
    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata

    /// Returns git metadata using explicit process-coordinated refresh authority.
    func workspaceMetadata(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadata

    /// Returns metadata plus whether the stamped repository revision remained current.
    func workspaceMetadataSnapshot(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadataSnapshot
}

/// Default cache-generation behavior for readers that only implement a full
/// metadata read.
public extension WorkspaceGitMetadataReading {
    /// Returns uncached git metadata for `directory`.
    ///
    /// Reader implementations that cannot consume a tracked-path generation can
    /// rely on this default to conservatively bypass tracked-change cache reuse.
    func workspaceMetadata(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory)
    }

    func workspaceMetadataSnapshot(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadataSnapshot {
        GitWorkspaceMetadataSnapshot(
            metadata: await workspaceMetadata(
                for: directory,
                snapshotRequest: snapshotRequest
            ),
            isCurrent: true
        )
    }
}

extension GitMetadataService: WorkspaceGitMetadataReading {}
