/// Failure to route a diff note through the workspace's existing agent chat session.
enum WorkspaceChangesAgentError: Error {
    /// No live chat session or authenticated chat source is currently available.
    case unavailable
}
