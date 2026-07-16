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
    let isActive: Bool
    let isMultiSelected: Bool
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

    var fontScale: CGFloat { settings.sidebarFontScale }

    func scaled(_ base: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(base * fontScale, percent: globalFontMagnificationPercent)
    }
}

/// Behavior bundle for the row view; excluded from model equality.
@MainActor
struct SidebarWorkspaceRowActions {
    let commands: SidebarWorkspaceRowCommands
    let onOpenPullRequest: (URL) -> Void
    let onOpenPort: (Int) -> Void
    let onToggleChecklistExpansion: () -> Void
    let onConsumeChecklistAddFieldActivation: () -> Void
    let checklistSetItemState: (UUID, WorkspaceChecklistItem.State) -> Void
    let checklistRemoveItem: (UUID) -> Void
    let checklistAddItem: (String) -> Void
    let checklistEditItem: (UUID, String) -> Void
    let commitRename: (String) -> Void
}
