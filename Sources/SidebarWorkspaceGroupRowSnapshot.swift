import AppKit
import CmuxSettings
import Foundation

/// Immutable presentation and menu state for one workspace-group row.
///
/// Live group, notification, config, and drag models are reduced to this
/// value above the AppKit table. Only action closures are bound when a cell
/// is configured; hover is injected per-cell by the table controller and is
/// deliberately not part of this value, so equivalence checks skip it.
struct SidebarWorkspaceGroupRowSnapshot: Equatable {
    let groupId: UUID
    let anchorWorkspaceId: UUID
    let name: String
    let iconSymbol: String
    let tintHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let memberCount: Int
    let anchorUnreadCount: Int
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotifications: Bool
    let canMarkAllRead: Bool
    let canMarkAllUnread: Bool
    let shortcutDigit: Int?
    let shortcutModifierSymbol: String?
    let showsShortcutHint: Bool
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
}
