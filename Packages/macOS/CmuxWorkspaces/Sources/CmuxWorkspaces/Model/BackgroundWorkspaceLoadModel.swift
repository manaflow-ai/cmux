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

    /// Records that `workspaceId` has begun a background terminal load.
    ///
    /// No-op when the id is already pending, preserving the legacy
    /// set-equality short-circuit (an unchanged set is never reassigned).
    public func requestBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard !pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
    }

    /// Marks `workspaceId`'s background load complete and releases the mount it
    /// pinned. No-op when the id was not pending.
    public func completeBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
        releaseBackgroundWorkspaceMount(for: workspaceId)
    }

    /// Pins `workspaceId` mounted on behalf of background-load bookkeeping.
    /// No-op when already pinned.
    public func retainBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard !mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    /// Releases the background-load mount pin for `workspaceId`. No-op when not
    /// pinned.
    public func releaseBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    /// Pins `workspaceIds` mounted for DEBUG inspection, unioning into the
    /// existing set. No-op when the input is empty or adds nothing new
    /// (the legacy set-equality short-circuit).
    public func retainDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.formUnion(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    /// Removes `workspaceIds` from the DEBUG inspection pin set. No-op when the
    /// input is empty or removes nothing (the legacy set-equality short-circuit).
    public func releaseDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.subtract(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    /// Drops any bookkeeping ids no longer backed by a live workspace by
    /// intersecting each set with `existingIds`. Each set is reassigned only
    /// when the intersection differs (the legacy set-equality short-circuit).
    public func pruneBackgroundWorkspaceLoads(existingIds: Set<UUID>) {
        let pruned = pendingBackgroundWorkspaceLoadIds.intersection(existingIds)
        if pruned != pendingBackgroundWorkspaceLoadIds {
            pendingBackgroundWorkspaceLoadIds = pruned
        }
        let mounted = mountedBackgroundWorkspaceLoadIds.intersection(existingIds)
        if mounted != mountedBackgroundWorkspaceLoadIds {
            mountedBackgroundWorkspaceLoadIds = mounted
        }
        let retained = debugPinnedWorkspaceLoadIds.intersection(existingIds)
        if retained != debugPinnedWorkspaceLoadIds {
            debugPinnedWorkspaceLoadIds = retained
        }
    }
}
