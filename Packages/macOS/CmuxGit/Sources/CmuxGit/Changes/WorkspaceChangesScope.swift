/// Resolved Git comparison scope for one workspace directory.
struct WorkspaceChangesScope: Sendable {
    let repoRoot: String
    let branch: String?
    let baseRef: String?
    let diffBase: String
    let diffBaseCommitOID: String
}
