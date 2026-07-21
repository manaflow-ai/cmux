import Combine
import CmuxWorkspaces
import Foundation
import Observation

/// The workspace-owned todo state: the manual task-status override and the
/// persisted checklist. A separate `@Observable` model (held as a `let` on
/// `Workspace`, like `sidebarAgentRuntimeObservation`) so todo churn publishes
/// through its own object and sidebar rows can observe it without
/// invalidating on unrelated `Workspace` observation traffic.
///
/// All mutation goes through the `Workspace` entry points in
/// `Workspace+Todos.swift` (shared by socket verbs, CLI, and UI) so caps,
/// text normalization, and override anti-rot apply identically everywhere.
@MainActor
@Observable
final class WorkspaceTodoState {
    /// Legacy Combine bridge for the remaining `.$statusOverride` subscribers. Emits the
    /// new value during willSet and replays the current value on subscribe — the
    /// exact `Published.Publisher` semantics those call sites were written
    /// against. Delete when the subscribers move to @Observable observation.
    @ObservationIgnored let statusOverridePublisher = CurrentValueSubject<WorkspaceTaskStatusOverride?, Never>(nil)
    /// The manual status override, or `nil` when the status is automatic.
    /// Carries the inference recorded at override time so a stale override
    /// auto-expires (see `WorkspaceTaskStatusOverride.effectiveStatus`).
    var statusOverride: WorkspaceTaskStatusOverride? {
        willSet { statusOverridePublisher.send(newValue) }
    }
    /// Legacy Combine bridge for the remaining `.$statusHidden` subscribers. Emits the
    /// new value during willSet and replays the current value on subscribe — the
    /// exact `Published.Publisher` semantics those call sites were written
    /// against. Delete when the subscribers move to @Observable observation.
    @ObservationIgnored let statusHiddenPublisher = CurrentValueSubject<Bool, Never>(true)
    /// When true, this workspace opts out of the status feature: no glyph is
    /// drawn before the title (a "None" state, distinct from Auto which still
    /// infers and shows a glyph). Selecting Auto or any lane clears it.
    var statusHidden: Bool = true {
        willSet { statusHiddenPublisher.send(newValue) }
    }
    /// Legacy Combine bridge for the remaining `.$checklist` subscribers. Emits the
    /// new value during willSet and replays the current value on subscribe — the
    /// exact `Published.Publisher` semantics those call sites were written
    /// against. Delete when the subscribers move to @Observable observation.
    @ObservationIgnored let checklistPublisher = CurrentValueSubject<[WorkspaceChecklistItem], Never>([])
    /// The persisted checklist, in display order.
    var checklist: [WorkspaceChecklistItem] = [] {
        willSet { checklistPublisher.send(newValue) }
    }
}
