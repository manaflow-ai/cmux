public import Foundation

/// The outcome of `workspace.env` (issue #5995): a read that resolves a
/// workspace strictly for explicit targets and returns its user-defined
/// environment.
///
/// The legacy body validated each explicit target key before resolving (this
/// endpoint can print secrets, so a malformed or stale explicit target must
/// error rather than silently fall back to the selected workspace — that
/// per-key validation stays in the coordinator), then resolved a TabManager and
/// a workspace, falling back to the selected workspace only when no explicit
/// target was supplied.
public enum ControlWorkspaceEnvResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found",
    /// `data: nil`).
    case notFound
    /// The workspace resolved. Carries its window id (may be absent), its id,
    /// and the user-defined environment dictionary (the legacy
    /// `workspaceEnvironment`); the coordinator reports `count == env.count`.
    case resolved(windowID: UUID?, workspaceID: UUID, env: [String: String])
}
