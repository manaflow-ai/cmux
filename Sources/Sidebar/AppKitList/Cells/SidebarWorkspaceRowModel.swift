import CmuxFoundation
import CmuxWorkspaces
import CoreGraphics
import Foundation
import SwiftUI

/// Immutable render input for one pure-AppKit sidebar workspace row.
///
/// Carries the existing row snapshot plus the row-level values TabItemView
/// received as parameters; the view derives every color/font/visibility from
/// these values only (snapshot-boundary discipline in AppKit form).
struct SidebarWorkspaceRowModel: Equatable {
    let workspaceId: UUID
    let index: Int
    let snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    let settings: SidebarTabItemSettingsSnapshot
    // `var` (not `let`) so the optimistic press/deselect paint can apply a
    // selection-flipped copy of the model; the stored model stays
    // authoritative and reconciles on the next configure.
    var isActive: Bool
    var isMultiSelected: Bool
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    let latestNotificationText: String?
    let showsAgentActivity: Bool
    let rowSpacing: CGFloat
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    let isGrouped: Bool
    let isFirstRow: Bool
    /// Resolved modifier-hold hint text (nil hides the pill).
    let shortcutHintText: String?
    let showsShortcutHints: Bool
    let colorSchemeIsDark: Bool
    let globalFontMagnificationPercent: Int
    let isChecklistExpanded: Bool
    let checklistAddFieldActivationToken: Int
    /// Whether the container presents this row's checklist popover
    /// (`checklistPopoverWorkspaceId == workspaceId`) — container-owned, like
    /// the legacy row's `isChecklistPopoverPresented`, so context-menu and
    /// palette "Add Checklist Item…" requests can open the popover.
    let isChecklistPopoverPresented: Bool
    /// The checklist item currently in tap-to-edit, container-owned so the
    /// prototype height measurement sees the same edit-field swap as the
    /// live cell.
    let editingChecklistItemId: UUID?
    /// Parity with legacy SidebarMetadataRows / markdown blocks: collapsed
    /// shows 3 entries / 1 block with a Show more toggle; expansion state is
    /// container-owned so the toggle re-measures heights through the normal
    /// apply pass.
    let isMetadataExpanded: Bool
    let isMarkdownExpanded: Bool

    var fontScale: CGFloat { settings.sidebarFontScale }

    func scaled(_ base: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(base * fontScale, percent: globalFontMagnificationPercent)
    }
}

/// Behavior bundle for the row view; excluded from model equality.
@MainActor
struct SidebarAppKitRowActions {
    let commands: SidebarWorkspaceRowCommands
    let onOpenStatusURL: (URL) -> Void
    let onOpenPullRequest: (URL) -> Void
    let onOpenPort: (Int) -> Void
    let onToggleChecklistExpansion: () -> Void
    let onToggleMetadataExpansion: () -> Void
    let onToggleMarkdownExpansion: () -> Void
    let onConsumeChecklistAddFieldActivation: () -> Void
    let checklistSetItemState: (UUID, WorkspaceChecklistItem.State) -> Void
    let checklistRemoveItem: (UUID) -> Void
    let checklistAddItem: (String) -> Void
    let checklistEditItem: (UUID, String) -> Void
    /// Moves one item toward a new 0-based position (within its completion
    /// partition; used by the checklist popover's todo-pane parity actions).
    let checklistMoveItem: (UUID, Int) -> Void
    /// Opens the workspace's todo pane (checklist popover footer).
    let checklistOpenPane: () -> Void
    let checklistAddAttachments: (UUID) -> Void
    let checklistRemoveAttachment: (UUID, UUID) -> Void
    let checklistOpenAttachments: (UUID, UUID?) -> Void
    /// Container write for `isChecklistPopoverPresented` (mirrors the legacy
    /// `onChecklistPopoverPresentedChange` action).
    let onChecklistPopoverPresentedChange: (Bool) -> Void
    /// Container write for `editingChecklistItemId` (`nil` ends editing).
    let onBeginChecklistItemEdit: (UUID?) -> Void
    /// Applies a manual status override to this row's workspace (`nil`
    /// returns the status to automatic).
    let applyTodoStatus: (WorkspaceTaskStatus?) -> Void
    /// Opts this row's workspace out of the status feature (None).
    let hideTodoStatus: () -> Void
    let commitRename: (String) -> Void
}


/// Per-sidebar memo of workspace snapshots so container re-renders (divider
/// drags re-render every frame) reuse cached snapshots; only pump events and
/// settings changes recompute. Plain box, never observed.
@MainActor
final class SidebarRowSnapshotCache {
    private var snapshotsById: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
    private var settingsFingerprint: SidebarTabItemSettingsSnapshot?

    func resetIfSettingsChanged(_ settings: SidebarTabItemSettingsSnapshot) {
        guard settingsFingerprint != settings else { return }
        settingsFingerprint = settings
        snapshotsById.removeAll(keepingCapacity: true)
    }

    func value(for id: UUID) -> SidebarWorkspaceSnapshotBuilder.Snapshot? {
        snapshotsById[id]
    }

    func store(_ snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot, for id: UUID) {
        snapshotsById[id] = snapshot
    }

    func prune(keeping ids: Set<UUID>) {
        guard snapshotsById.count > ids.count else { return }
        snapshotsById = snapshotsById.filter { ids.contains($0.key) }
    }
}
