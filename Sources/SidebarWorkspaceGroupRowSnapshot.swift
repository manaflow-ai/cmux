import AppKit
import CmuxSettings
import Foundation

/// Immutable presentation and menu state for one workspace-group row.
///
/// Live group, notification, config, drag, and pointer models are reduced to
/// this value before the lazy-list boundary. Only action closures are bound
/// when SwiftUI realizes the row.
struct SidebarWorkspaceGroupRowSnapshot {
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
    let isPointerHovering: Bool
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
    let shouldCollectWorkspaceDropTargets: Bool
}
