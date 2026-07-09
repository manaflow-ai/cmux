import Combine
import CmuxWorkspaces
import Foundation

/// The workspace-owned todo state: the manual task-status override and the
/// persisted checklist. A separate `@Observable` sub-model (held as a `let`
/// on `Workspace`, like `sidebarAgentRuntimeObservation`) so todo churn is
/// tracked through its own object and sidebar rows can observe it without
/// registering unrelated `Workspace` properties.
///
/// All mutation goes through the `Workspace` entry points in
/// `Workspace+Todos.swift` (shared by socket verbs, CLI, and UI) so caps,
/// text normalization, and override anti-rot apply identically everywhere.
@MainActor
@Observable
final class WorkspaceTodoState {
    /// The manual status override, or `nil` when the status is automatic.
    /// Carries the inference recorded at override time so a stale override
    /// auto-expires (see `WorkspaceTaskStatusOverride.effectiveStatus`).
    var statusOverride: WorkspaceTaskStatusOverride?
    /// When true, this workspace opts out of the status feature: no glyph is
    /// drawn before the title (a "None" state, distinct from Auto which still
    /// infers and shows a glyph). Selecting Auto or any lane clears it.
    var statusHidden: Bool = false
    /// The persisted checklist, in display order.
    var checklist: [WorkspaceChecklistItem] = []
}
