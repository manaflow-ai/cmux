public import Foundation
public import CmuxCore

/// The live-workspace operations ``WorkspaceUnreadModel`` reaches back into.
///
/// ``WorkspaceUnreadModel`` owns the per-workspace unread/restored-indicator
/// state (the former `Workspace.manualUnreadPanelIds` /
/// `Workspace.restoredUnreadPanelIndicators` / `Workspace.manualUnreadMarkedAt`)
/// and the pure state-transition logic the legacy `Workspace` god object kept
/// inline. Everything the transitions need that is *not* unread state, the live
/// panel set, the bonsplit tab badge, the workspace's `TerminalNotificationStore`
/// reads/writes, and the SwiftUI change signal, is irreducibly app-coupled, so
/// the model calls it through this seam. The app target's `Workspace` conforms
/// and is injected via ``WorkspaceUnreadModel/attach(host:)``.
///
/// Every method mirrors a call the legacy method bodies made on `self`
/// (`panels`, `bonsplitController`, `AppDelegate.shared?.notificationStore`,
/// `surfaceIdFromPanelId`, `representativePanelIdForWorkspaceManualUnread`,
/// `hasVisibleNotificationIndicator`) so the move is byte-faithful.
@MainActor
public protocol WorkspaceUnreadHosting: AnyObject {
    /// Whether a panel with `panelId` currently exists in the workspace
    /// (legacy `panels[panelId] != nil`).
    func workspaceUnreadPanelExists(_ panelId: UUID) -> Bool

    /// The current set of panel ids in the workspace (legacy `panels.keys`).
    func workspaceUnreadPanelIds() -> Set<UUID>

    /// Whether the panel currently maps to a bonsplit tab (legacy
    /// `surfaceIdFromPanelId(panelId) != nil` guard). When `false`,
    /// ``WorkspaceUnreadModel/syncUnreadBadgeStateForPanel(_:)`` does nothing,
    /// matching the legacy early return.
    func workspaceUnreadPanelHasTab(_ panelId: UUID) -> Bool

    /// Whether the panel currently shows a visible notification indicator
    /// (legacy `notificationStore?.hasVisibleNotificationIndicator(forTabId:surfaceId:)`,
    /// the body of the legacy private `Workspace.hasVisibleNotificationIndicator(panelId:)`).
    func workspaceUnreadHasVisibleNotificationIndicator(panelId: UUID) -> Bool

    /// Whether the panel has an unread notification in the notification store
    /// (legacy `notificationStore?.hasUnreadNotification(forTabId:surfaceId:)`,
    /// the body of the legacy private `Workspace.hasUnreadNotification(panelId:)`).
    func workspaceUnreadHasUnreadNotification(panelId: UUID) -> Bool

    /// The panel currently showing the focused-read indicator, used to build the
    /// attention-flash persistent state (legacy
    /// `notificationStore?.focusedReadIndicatorSurfaceId(forTabId:)`).
    func workspaceUnreadFocusedReadPanelId() -> UUID?

    /// Plays the per-panel attention flash for an allowed flash decision
    /// (legacy `panels[panelId]?.triggerFlash(reason:)`). A no-op when the panel
    /// is absent, matching the legacy optional-chain.
    func workspaceUnreadTriggerPanelFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason)

    /// Whether the workspace itself is marked manually unread in the
    /// notification store (legacy `notificationStore?.hasManualUnread(forTabId:)`).
    func workspaceUnreadNotificationHasManualUnread() -> Bool

    /// The panel id that represents the workspace-level manual-unread badge
    /// (legacy `representativePanelIdForWorkspaceManualUnread()`).
    func workspaceUnreadRepresentativePanelId() -> UUID?

    /// Applies the resolved badge visibility to the panel's bonsplit tab,
    /// guarded against redundant writes exactly as the legacy body
    /// (`if existing.showsNotificationBadge == shouldShow { return }`). The host
    /// resolves the tab id (the legacy `TabID` stays app/Bonsplit-side and never
    /// crosses into this package).
    func workspaceUnreadApplyBadge(panelId: UUID, showsNotificationBadge: Bool)

    /// Propagates the panel-derived workspace-unread flag to the notification
    /// store (legacy `notificationStore?.setPanelDerivedUnread(_:forTabId:)`).
    func workspaceUnreadSetPanelDerivedUnread(_ isUnread: Bool)

    /// Marks the panel read in the notification store
    /// (legacy `notificationStore?.markRead(forTabId:surfaceId:)`).
    func workspaceUnreadNotificationMarkRead(panelId: UUID)

    /// Marks the whole workspace read in the notification store
    /// (legacy `notificationStore?.markRead(forTabId:)`).
    func workspaceUnreadNotificationMarkReadWorkspace()

    /// Clears the workspace-level restored-unread indicator in the notification
    /// store (legacy `notificationStore?.clearRestoredUnreadIndicator(forTabId:)`).
    func workspaceUnreadNotificationClearRestoredUnreadIndicator()
}
