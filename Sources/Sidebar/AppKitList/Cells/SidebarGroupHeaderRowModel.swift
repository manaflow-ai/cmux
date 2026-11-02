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
    // `var` only so `hasHeightEquivalentContent` can neutralize the group
    // color when comparing heights; the stored value stays authoritative.
    var tintHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let isMultiSelected: Bool
    // `var` for the same height-comparison neutralization as `tintHex`: a
    // group recolor rewrites the multi-selection wash but not the header
    // height.
    var multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle
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
    /// Header band fill resolved before the list boundary, or `nil` when the
    /// group-divider setting is off. Paint-only: excluded from height
    /// equivalence (``hasHeightEquivalentContent(to:)``) so a group recolor
    /// repaints the band without evicting the AppKit row-height cache.
    var bandStyle: SidebarWorkspaceRowBackgroundStyle? = nil
    /// Whether the group-divider treatment is on. Height-bearing: the header
    /// metrics turn it into the 11↔12.5 pt name size, which changes the header
    /// height, so it stays in ``hasHeightEquivalentContent(to:)``.
    var showsGroupDividers: Bool = false
    /// Scaled top gap painted above the header band; `0` for the first
    /// rendered row or when the setting is off. Height-bearing.
    var topGap: CGFloat = 0
    /// Whether this header is the first row the list renders (the stable
    /// list-position fact, not the drag-only ``isFirstRow``); feeds ``topGap``
    /// and so is height-bearing.
    var isFirstRenderedRow: Bool = false

    /// Equality over every field that can influence the measured header height,
    /// mirroring ``SidebarWorkspaceRowModel/hasHeightEquivalentContent(to:)``.
    /// A group recolor rewrites `tintHex`, `bandStyle`, the multi-selection
    /// wash and the anchor-active hairline, none of which move the header, so
    /// those paint-only fields are neutralized while the top gap, first-row
    /// fact, divider flag, name and status content stay. The AppKit height
    /// cache keys on this, so a recolor repaints without re-measuring the
    /// header; toggling the setting (name size + gap) still does, correctly.
    func hasHeightEquivalentContent(to other: Self) -> Bool {
        if self == other { return true }
        var normalizedSelf = self
        var normalizedOther = other
        normalizedSelf.tintHex = nil
        normalizedOther.tintHex = nil
        normalizedSelf.bandStyle = nil
        normalizedOther.bandStyle = nil
        normalizedSelf.multiSelectionBackgroundStyle = .clear
        normalizedOther.multiSelectionBackgroundStyle = .clear
        normalizedSelf.anchorActiveEdgeColor = nil
        normalizedOther.anchorActiveEdgeColor = nil
        return normalizedSelf == normalizedOther
    }
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
