/// What the task runner needs from the workspace store (c8-composer.md 3).
/// No argv, cwd or environment from the phone reaches any of these.
public protocol MobileTaskWorkspaces: Sendable {
    /// Creates an empty workspace; returns its `ws_…` id.
    func createWorkspace(idempotencyKey: String) async throws -> String
    /// The directory the workspace's agents start in, made when the store has none.
    func directory(of workspace: String) async throws -> String
    /// Opens an agent chat tab on `session` in the workspace; returns its `tab_…` id.
    func openAgentTab(workspace: String, session: String, harness: String, idempotencyKey: String) async throws -> String
}
