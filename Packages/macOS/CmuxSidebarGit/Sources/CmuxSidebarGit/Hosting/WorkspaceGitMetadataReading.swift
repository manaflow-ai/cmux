public import CmuxGit

/// Reads a directory's on-disk git metadata (branch, dirty state, index and
/// head signatures) off the main actor. Injected into
/// ``SidebarGitMetadataService`` so tests can supply a fake reader without
/// touching the filesystem.
public protocol WorkspaceGitMetadataReading: Sendable {
    /// Returns the git metadata for `directory`.
    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata

    /// Returns the git metadata for `directory`, reusing tracked-change work
    /// only when the supplied watcher generation has not changed.
    func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: UInt64?
    ) async -> GitWorkspaceMetadata
}

public extension WorkspaceGitMetadataReading {
    func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: UInt64?
    ) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory)
    }
}

extension GitMetadataService: WorkspaceGitMetadataReading {}
