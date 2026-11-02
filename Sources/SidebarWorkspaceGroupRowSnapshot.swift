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
    let isMultiSelected: Bool
    let multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle
    /// Hairline painted while this header is anchor-active; nil when subtle
    /// selection is off.
    var anchorActiveEdgeColor: NSColor? = nil
    let memberCount: Int
    let anchorUnreadCount: Int
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotifications: Bool
    let canMarkAllRead: Bool
    let canMarkAllUnread: Bool
    let statusGlyph: SidebarCompactStatusGlyph?
    /// Whether `sidebar.compactAgentStatus` is on; see the AppKit row model.
    var compactsAgentStatus = false
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
    let notificationBadgeColorHex: String?
    /// Header band fill resolved before the list boundary, or `nil` when the
    /// group-divider setting is off. Carried for the SwiftUI header renderer.
    var bandStyle: SidebarWorkspaceRowBackgroundStyle? = nil
    /// Whether the group-divider treatment is on; the header metrics turn it
    /// into the 11↔12.5 pt name size.
    var showsGroupDividers = false
    /// Scaled top gap above the header band; `0` for the first rendered row or
    /// when the setting is off.
    var topGap: CGFloat = 0
    /// Whether this header is the first row the list renders (the stable
    /// list-position fact, not the drag-only ``isFirstRow``); feeds ``topGap``.
    var isFirstRenderedRow = false
}
