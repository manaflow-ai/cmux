public import Foundation

/// The outcome of `workspace.reorder`, after the coordinator has confirmed a
/// TabManager resolves and validated the `workspace_id` / single-target params.
public enum ControlWorkspaceReorderResolution: Sendable, Equatable {
    /// No plan could be built for the workspace (legacy `not_found` / "Workspace
    /// not found", data carries only `workspace_id`).
    case notFound
    /// A plan was built (and applied unless dry-run). Carries the owning window
    /// id (may be absent) and the single plan item.
    case resolved(windowID: UUID?, plan: ControlWorkspaceReorderPlanItem)
}
