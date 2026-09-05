import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Value-snapshot render input for one pure-AppKit sidebar group header row.
///
/// Value fields only: action closures live in ``SidebarGroupHeaderRowActions``
/// and are excluded from equality so recycled cells can reconfigure cheaply
/// (same discipline as the hosted rows' Equatable snapshot contract).
struct SidebarGroupHeaderRowModel: Equatable, Hashable {
    let groupId: UUID
    let anchorWorkspaceId: UUID
    let name: String
    let iconSymbol: String
    let tintHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let isMultiSelected: Bool
    let multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle
    let memberCount: Int
    var anchorUnreadCount: Int
    var canMarkRead: Bool
    var canMarkUnread: Bool
    var hasLatestNotifications: Bool
    var canMarkAllRead: Bool
    var canMarkAllUnread: Bool
    /// Resolved modifier-hold hint (for example "⌘3"); nil hides the pill.
    let shortcutHintText: String?
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let globalFontMagnificationPercent: Int
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    /// Resolved cmux scheme used by native group-header chrome.
    let colorSchemeIsDark: Bool
}

/// Behavior bundle for one group header row; recreated per apply and excluded
/// from model equality.
@MainActor
struct SidebarGroupHeaderRowActions {
    let onToggleCollapsed: () -> Void
    let onFocusAnchor: (NSEvent.ModifierFlags) -> Void
    let onTapPlus: () -> Void
    let onRunResolvedItem: (CmuxResolvedConfigMenuAction) -> Void
    let onRename: () -> Void
    let onTogglePinned: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onClearLatestNotifications: () -> Void
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void
    let onUngroup: () -> Void
    let onDelete: () -> Void
    let onEditConfig: () -> Void
    let onOpenDocs: () -> Void
    /// Resolves current notification availability for retained rows.
    var notificationState: () -> NotificationState = { .unavailable }
}
