public import Foundation
public import Observation

/// The per-window background-workspace-load + cycle-hot sub-model: owns the
/// transient bookkeeping the legacy `TabManager` god object kept in its
/// `@Published pendingBackgroundWorkspaceLoadIds` /
/// `mountedBackgroundWorkspaceLoadIds` / `debugPinnedWorkspaceLoadIds` /
/// `isWorkspaceCycleHot` properties.
///
/// These four values are the read inputs the ``WorkspaceHandoffCoordinator``
/// consumes through ``WorkspaceHandoffHosting`` (the mounted/debug-pinned id
/// sets and the cycle-hot flag widen the mount budget), plus the pending-load
/// set the background-prime flow drains. The window's `TabManager` composition
/// root owns one instance, mutates it from its background-load/cycle entry
/// points, and exposes read-only computed forwarders.
///
/// `@Observable` is the single observation mechanism: SwiftUI views and
/// app-side observers track these properties via Observation
/// (`withObservationTracking` / `.onChange`) instead of the retired
/// `@Published` Combine bridges. Mutation is single-writer on the MainActor
/// (the owning `TabManager`); set-equality short-circuits live at the call
/// sites, matching the legacy property-observer behavior.
@MainActor
@Observable
public final class BackgroundWorkspaceLoadModel {
    /// Workspace ids whose background terminal load has been requested but not
    /// yet completed (legacy `tabManager.pendingBackgroundWorkspaceLoadIds`).
    public var pendingBackgroundWorkspaceLoadIds: Set<UUID> = []

    /// Workspace ids pinned mounted by background-load bookkeeping (legacy
    /// `tabManager.mountedBackgroundWorkspaceLoadIds`).
    public var mountedBackgroundWorkspaceLoadIds: Set<UUID> = []

    /// Workspace ids pinned mounted for DEBUG inspection (legacy
    /// `tabManager.debugPinnedWorkspaceLoadIds`).
    public var debugPinnedWorkspaceLoadIds: Set<UUID> = []

    /// Whether a workspace cycle is in progress (legacy
    /// `tabManager.isWorkspaceCycleHot`), which widens the mount budget to the
    /// handoff pair and warms the selected workspace.
    public var isWorkspaceCycleHot: Bool = false

    /// Creates an empty model; the owning window mutates it as background loads
    /// and workspace cycles begin and end.
    public init() {}
}
