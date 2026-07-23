/// One capped changed-file snapshot with aggregate metadata.
struct WorkspaceChangesSnapshot: Sendable {
    let scope: WorkspaceChangesScope
    let files: [WorkspaceChangedFile]
    let totalFileCount: Int
    let additions: Int
    let deletions: Int
}
