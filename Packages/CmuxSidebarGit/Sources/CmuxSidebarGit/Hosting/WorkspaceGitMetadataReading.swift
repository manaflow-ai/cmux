public import CmuxGit

/// Reads a directory's on-disk git metadata (branch, dirty state, index and
/// head signatures) off the main actor. Injected into
/// ``SidebarGitMetadataService`` so tests can supply a fake reader without
/// touching the filesystem.
public protocol WorkspaceGitMetadataReading: Sendable {
    /// Returns the git metadata for `directory`.
    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata
}

extension GitMetadataService: WorkspaceGitMetadataReading {}
