/// One off-main filesystem snapshot for a missing Git config dependency.
struct WorkspaceGitMetadataCreationTargetSnapshot: Sendable {
    let exists: Bool
    let nearestExistingDirectory: String
}
