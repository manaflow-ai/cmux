import CmuxAppKitSupportUI
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
    // `var` only so `hasHeightEquivalentContent` can compare
    // position-neutralized copies; the stored value stays authoritative.
    var index: Int
    let snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    let settings: SidebarTabItemSettingsSnapshot
    // `var` (not `let`) so the optimistic press/deselect paint can apply a
    // selection-flipped copy of the model; the stored model stays
    // authoritative and reconciles on the next configure.
    var isActive: Bool
    var isMultiSelected: Bool
    /// Whether the workspace already has a user-owned custom title; baseline
    /// input for the inline-rename commit policy (committing an unchanged
    /// automatic title must not convert it into a user title, which would
    /// freeze auto-naming).
    let hasUserCustomTitle: Bool
    let canCloseWorkspace: Bool
    // `var` only for `hasHeightEquivalentContent` (see `index`); every row
    // carries it, so a create or close changes it on the whole list.
    var accessibilityWorkspaceCount: Int
    var unreadCount: Int
    var latestNotificationText: String?
    let showsAgentActivity: Bool
    // The fields below through `showsShortcutHints` are `var` only for
    // `hasHeightEquivalentContent` (see `index`): they paint chrome that the
    // measurement pass never reads.
    var rowSpacing: CGFloat
    var isBeingDragged: Bool
    var topDropIndicatorVisible: Bool
    var bottomDropIndicatorVisible: Bool
    let isGrouped: Bool
    var isFirstRow: Bool
    /// Resolved modifier-hold hint text (nil hides the pill).
    var shortcutHintText: String?
    var showsShortcutHints: Bool
    let colorSchemeIsDark: Bool
    /// Hex of the opaque terminal-matched backdrop (secondary text holds a
    /// contrast floor over it), or `nil` over the sidebar material.
    var readabilityBackdropHex: String? = nil
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
    /// `WorkspaceTodoFeature.isEnabled`, projected at model-build time so a
    /// remote rollout / local opt-in flip changes the model (and therefore
    /// reconfigures and re-measures rows) instead of being read as a live
    /// global inside the cell where nothing observes it.
    let todoControlsEnabled: Bool
    /// Parity with legacy SidebarMetadataRows / markdown blocks: collapsed
    /// shows 3 entries / 1 block with a Show more toggle; expansion state is
    /// container-owned so the toggle re-measures heights through the normal
    /// apply pass.
    let isMetadataExpanded: Bool
    let isMarkdownExpanded: Bool
    /// macOS Display accessibility settings (Differentiate Without Color,
    /// Increase Contrast) the row paints with. Part of equality so a
    /// System Settings change repaints visible rows.
    var displayAccessibility: DisplayAccessibilityOptions = .standard

    var fontScale: CGFloat { settings.sidebarFontScale }

    func scaled(_ base: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(base * fontScale, percent: globalFontMagnificationPercent)
    }

    /// Equality over every field that can influence the measured row height.
    /// `index` and `accessibilityWorkspaceCount` feed only the accessibility
    /// label; `isFirstRow`, `rowSpacing` and the drop indicators only the
    /// apply-pass chrome frames (`layoutContent(apply: true)`); the shortcut
    /// hint pill is an overlay; dragging only dims the row; and the unread
    /// count matters only as badge visibility (the badge side is fixed). None
    /// changes what `layoutContent(apply: false)` returns. Closing or creating
    /// a workspace, holding the hint modifier, or a drag changes these on many
    /// rows at once; keying the height cache on full equality re-measured the
    /// whole list on the main actor and lost the entries a stale-width
    /// fallback needs.
    func hasHeightEquivalentContent(to other: Self) -> Bool {
        if self == other { return true }
        return heightNormalized == other.heightNormalized
    }

    private var heightNormalized: Self {
        var normalized = self
        normalized.index = 0
        normalized.isFirstRow = false
        normalized.accessibilityWorkspaceCount = 0
        normalized.unreadCount = unreadCount > 0 ? 1 : 0
        normalized.rowSpacing = 0
        normalized.isBeingDragged = false
        normalized.topDropIndicatorVisible = false
        normalized.bottomDropIndicatorVisible = false
        normalized.shortcutHintText = nil
        normalized.showsShortcutHints = false
        return normalized
    }
}

/// Behavior bundle for the row view; excluded from model equality.
@MainActor
struct SidebarAppKitRowActions {
    let commands: SidebarWorkspaceRowCommands
    let onOpenStatusURL: (URL) -> Void
    let onOpenWorkspaceDescriptionURL: (URL) -> Void
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
    /// Ends the edit session for ONE item — a no-op when the container has
    /// already moved on to another item (an old editor's teardown commit
    /// must not clear a newly selected item's session).
    let onEndChecklistItemEdit: (UUID) -> Void
    /// Applies a manual status override to this row's workspace (`nil`
    /// returns the status to automatic).
    let applyTodoStatus: (WorkspaceTaskStatus?) -> Void
    /// Opts this row's workspace out of the status feature (None).
    let hideTodoStatus: () -> Void
    let commitRename: (String) -> Void
}
