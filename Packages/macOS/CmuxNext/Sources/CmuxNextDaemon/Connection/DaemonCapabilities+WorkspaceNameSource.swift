/// Workspace name provenance capability used by the daemon wire client.
extension DaemonCapabilities {
    /// Workspace name provenance and revision (`name_source`, `name_revision`).
    public var workspaceNameSource: String { "workspace-name-source-v1" }
}
