import AppKit
import CoreGraphics
import CmuxFoundation
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
    /// Hairline painted while this header is anchor-active; nil when subtle
    /// selection is off.
    var anchorActiveEdgeColor: NSColor? = nil
    let memberCount: Int
    var anchorUnreadCount: Int
    var canMarkRead: Bool
    var canMarkUnread: Bool
    var hasLatestNotifications: Bool
    var canMarkAllRead: Bool
    var canMarkAllUnread: Bool
    /// Compact status mode: the loudest state among the workspaces the header
    /// stands in for; see ``SidebarCompactStatusGlyph/groupHeader(isCollapsed:anchorId:memberIds:members:unread:)``.
    var statusGlyph: SidebarCompactStatusGlyph?
    /// Whether `sidebar.compactAgentStatus` is on. Compact mode shows unread
    /// as the glyph, so the numeric badge never returns, not even when no
    /// member state is loud enough to roll up.
    var compactsAgentStatus = false
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
    /// Notification Badge color setting; nil falls back to the cmux accent.
    let notificationBadgeColorHex: String?
    /// Resolved cmux accent for the badge fallback and drop indicators.
    var accentColor = CmuxAccentColor()
    /// A derived automatic Group By section: the header only collapses, and
    /// hides its plus button and group menu.
    var isAutomaticSection = false
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
