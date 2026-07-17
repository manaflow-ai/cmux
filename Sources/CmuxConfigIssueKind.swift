enum CmuxConfigIssueKind: String, Sendable {
    case newWorkspaceActionNotFound
    case newWorkspaceCommandNotFound
    case newWorkspaceCommandRequiresWorkspace
    case schemaError
}
