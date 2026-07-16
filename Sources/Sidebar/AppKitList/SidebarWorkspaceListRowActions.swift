import AppKit
import Foundation

/// Closure capabilities for one workspace-group header row.
///
/// Mirrors the closures the SwiftUI `SidebarWorkspaceGroupHeaderView` received;
/// the AppKit header cell and its `NSMenu` invoke these and never touch live
/// models.
@MainActor
struct SidebarWorkspaceGroupHeaderActions {
    let onToggleCollapsed: () -> Void
    let onFocusAnchor: () -> Void
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
}

/// Per-row action bundle resolved lazily when the table wires or interacts
/// with a cell. Workspace rows reuse the exact closure surface the SwiftUI
/// rows consumed.
@MainActor
enum SidebarWorkspaceListCellActions {
    case workspace(SidebarWorkspaceRowActions)
    case groupHeader(SidebarWorkspaceGroupHeaderActions)
}

/// Resolves the action bundle for a row on demand.
///
/// Actions capture parent-owned models, so the parent hands the table one
/// resolver per apply pass instead of materializing closure bundles for every
/// row up front.
typealias SidebarWorkspaceListActionResolver =
    @MainActor (SidebarWorkspaceListRow) -> SidebarWorkspaceListCellActions?
