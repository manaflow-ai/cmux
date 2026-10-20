public import Foundation

/// The outcome of `workspace.reorder_many`, after the coordinator has parsed and
/// resolved the ordered workspace ids. Preserves the legacy body's failures and
/// the success plan list. The localized messages are supplied via
/// ``ControlWorkspaceStrings`` so they resolve against the app bundle.
public enum ControlWorkspaceReorderManyResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable`, localized
    /// `reorderMany.tabManagerUnavailable`).
    case tabManagerUnavailable
    /// A workspace appeared more than once in the order (legacy `invalid_params`,
    /// localized `reorderMany.duplicateWorkspace`, data carries the workspace
    /// identity).
    case duplicateWorkspace(UUID)
    /// A workspace in the order was not found (legacy `not_found`, localized
    /// `reorderMany.workspaceNotFound`, data carries the workspace identity).
    case workspaceNotFound(UUID)
    /// The reorder planned (and applied unless dry-run). Carries the owning
    /// window id (may be absent) and the per-workspace plan items.
    case resolved(windowID: UUID?, plans: [ControlWorkspaceReorderPlanItem])
}
