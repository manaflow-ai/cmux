public import Foundation
import Observation

/// Per-window sidebar multi-selection state: the set of workspace ids the
/// user has Shift/Cmd-selected in the sidebar, plus the two NotificationCenter
/// events that keep the sidebar's SwiftUI selection in sync.
///
/// `@MainActor` because every mutator and reader is a MainActor UI path
/// (TabManager group operations, AppDelegate batch actions, the SwiftUI
/// sidebar) — state lives where its callers live; an actor would only
/// manufacture suspension points inside what are single-turn updates today.
///
/// The decision guards around mutations (which workspaces are eligible,
/// whether focus moved) stay with the workspace/group logic that owns that
/// state; this model owns the selection set and the event posts.
@MainActor
@Observable
public final class SidebarMultiSelectionModel {
    /// The workspace ids currently multi-selected in the sidebar.
    public private(set) var selectedWorkspaceIds: Set<UUID> = []

    private let notificationCenter: NotificationCenter

    /// Creates an empty selection model posting events to `notificationCenter`.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    /// Whether the workspace is part of the multi-selection.
    public func contains(_ workspaceId: UUID) -> Bool {
        selectedWorkspaceIds.contains(workspaceId)
    }

    /// Replaces the selection wholesale.
    public func replaceSelection(with workspaceIds: Set<UUID>) {
        selectedWorkspaceIds = workspaceIds
    }

    /// Removes one workspace from the selection (workspace closed).
    public func removeFromSelection(_ workspaceId: UUID) {
        selectedWorkspaceIds.remove(workspaceId)
    }

    /// Removes the given workspaces from the selection.
    public func subtractSelection(_ workspaceIds: Set<UUID>) {
        selectedWorkspaceIds.subtract(workspaceIds)
    }

    /// Intersects the selection with the workspaces that still exist.
    public func intersectSelection(with workspaceIds: Set<UUID>) {
        selectedWorkspaceIds.formIntersection(workspaceIds)
    }

    /// Reduces the selection to a single workspace (or clears it when the
    /// workspace is not known to the window), then posts
    /// ``SidebarMultiSelectionShouldCollapseEvent`` so the SwiftUI sidebar
    /// selection collapses too. The post is unconditional, matching the
    /// legacy `clearSidebarMultiSelection(except:)`.
    public func collapseSelection(to workspaceId: UUID, isKnownWorkspace: Bool) {
        let next: Set<UUID> = isKnownWorkspace ? [workspaceId] : []
        if selectedWorkspaceIds != next {
            selectedWorkspaceIds = next
        }
        notificationCenter.post(
            name: SidebarMultiSelectionShouldCollapseEvent.notificationName,
            object: self,
            userInfo: SidebarMultiSelectionShouldCollapseEvent(focusedWorkspaceId: workspaceId).userInfo()
        )
    }

    /// Posts ``SidebarMultiSelectionDidHideEvent`` after the caller has
    /// applied the matching selection mutation (group create collapses to
    /// the anchor; group collapse subtracts the hidden members).
    public func postDidHide(hiddenWorkspaceIds: Set<UUID>, focusedWorkspaceId: UUID?) {
        notificationCenter.post(
            name: SidebarMultiSelectionDidHideEvent.notificationName,
            object: self,
            userInfo: SidebarMultiSelectionDidHideEvent(
                hiddenWorkspaceIds: hiddenWorkspaceIds,
                focusedWorkspaceId: focusedWorkspaceId
            ).userInfo()
        )
    }
}
