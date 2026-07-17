enum MobileWorkspaceDiffFileResult: Sendable {
    case repositoryNotFound
    case repositoryChanged
    case gitFailed
    case gitTimedOut
    case ok(path: String, unifiedDiff: String, truncated: Bool)
}
