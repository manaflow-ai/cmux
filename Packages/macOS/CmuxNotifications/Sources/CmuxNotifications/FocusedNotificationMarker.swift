public import Foundation

/// The focused-notification mark state machine: toggling the focused
/// notification's unread state, and marking it oldest-unread before jumping to
/// the next latest unread. Lifted verbatim from `AppDelegate`'s focused-mark
/// cluster (`toggleFocusedNotificationUnread`,
/// `markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`, the
/// `markFocusedNotificationAsOldestUnread` overloads), with every app-target
/// collaborator (`TerminalNotificationStore`, `Workspace`, the first-responder
/// `focusedTerminalShortcutContext`, the window contexts) reached through
/// ``FocusedNotificationResolving``.
///
/// A Coordinator-adjacent flow helper (CONVENTIONS §2): it sequences the
/// focused-mark flows and owns no state. The jump step is delegated back to the
/// owning ``NotificationNavigationCoordinator`` through an injected closure so
/// this type carries no jump logic of its own. `@MainActor` for parity with the
/// resolver and the legacy main-actor path.
@MainActor
public final class FocusedNotificationMarker {
    private let resolver: any FocusedNotificationResolving
    /// Delegates to `NotificationNavigationCoordinator.jumpToLatestUnread`,
    /// returning the opened notification id (or `nil`). Injected so the marker
    /// does not depend on the coordinator's other seams.
    private let jumpToLatestUnread: (
        _ excludingNotificationId: UUID?,
        _ excludingWorkspaceId: UUID?,
        _ excludingWindowDockTarget: WindowDockUnreadTarget?
    ) -> UUID?

    /// Creates a focused-notification marker driven by the injected resolver
    /// and jump closure.
    public init(
        resolver: any FocusedNotificationResolving,
        jumpToLatestUnread: @escaping (
            _ excludingNotificationId: UUID?,
            _ excludingWorkspaceId: UUID?,
            _ excludingWindowDockTarget: WindowDockUnreadTarget?
        ) -> UUID?
    ) {
        self.resolver = resolver
        self.jumpToLatestUnread = jumpToLatestUnread
    }

    /// The result of marking the focused notification oldest-unread, mirroring
    /// the app-target `FocusedNotificationMarkResult`.
    private enum MarkResult {
        case deferredNotification(
            id: UUID,
            windowDockTarget: WindowDockUnreadTarget?
        )
        case markedWorkspaceWithoutNotification(UUID)
        case markedWindowDockWithoutNotification(WindowDockUnreadTarget)
    }

    /// Toggles the focused notification's unread state, returning whether
    /// anything was toggled. Mirrors `toggleFocusedNotificationUnread`.
    @discardableResult
    public func toggleFocusedNotificationUnread(preferredWindowToken: AnyObject? = nil) -> Bool {
        // Mirrors `guard let notificationStore, let target = focusedNotificationTarget(...)`.
        guard resolver.hasNotificationStore,
              let target = resolver.focusedTarget(preferredWindowToken: preferredWindowToken) else {
            return false
        }
        switch target {
        case .windowDock(let dockTarget):
            if resolver.windowDockSurfaceIsUnread(dockTarget) {
                resolver.clearWindowDockSurfaceUnread(dockTarget)
            } else {
                resolver.markWindowDockSurfaceUnread(dockTarget)
            }
            return true
        case .workspace(let tabId, let surfaceId):
            return toggleWorkspaceNotificationUnread(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private func toggleWorkspaceNotificationUnread(tabId: UUID, surfaceId: UUID?) -> Bool {
        if let panel = resolver.focusedPanel(forTabId: tabId, surfaceId: surfaceId) {
            let focusedPanelHasRestoredUnread = resolver.panelHasRestoredUnread(panel)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: tabId) &&
                !focusedPanelHasRestoredUnread &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            if resolver.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: nil) ||
                hasWorkspaceOnlyRestoredUnread {
                resolver.storeMarkRead(forTabId: tabId)
                return true
            }
            let hasWorkspaceManualUnreadOnPanel =
                resolver.storeHasManualUnread(forTabId: tabId) &&
                resolver.panelIsRepresentativeForWorkspaceManualUnread(panel)
            let isPanelUnread =
                resolver.panelIsManualUnread(panel) ||
                focusedPanelHasRestoredUnread ||
                resolver.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: panel.panelId) ||
                hasWorkspaceManualUnreadOnPanel
            if isPanelUnread {
                resolver.markPanelRead(panel)
                if hasWorkspaceManualUnreadOnPanel {
                    resolver.storeClearManualUnread(forTabId: tabId)
                }
                return true
            }
            resolver.markPanelUnread(panel)
            return true
        }
        if resolver.workspaceIsUnread(forTabId: tabId) {
            resolver.storeMarkRead(forTabId: tabId)
            return true
        }
        resolver.storeMarkUnread(forTabId: tabId)
        return true
    }

    /// Marks the focused notification oldest-unread, then jumps to the next
    /// latest unread (excluding the deferred notification or marked workspace),
    /// returning the opened notification id. Mirrors
    /// `markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`.
    @discardableResult
    public func markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        preferredWindowToken: AnyObject? = nil
    ) -> UUID? {
        guard let result = markFocusedNotificationAsOldestUnread(preferredWindowToken: preferredWindowToken) else {
            return nil
        }
        switch result {
        case .deferredNotification(let notificationId, let windowDockTarget):
            return jumpToLatestUnread(notificationId, nil, windowDockTarget)
        case .markedWorkspaceWithoutNotification(let workspaceId):
            return jumpToLatestUnread(nil, workspaceId, nil)
        case .markedWindowDockWithoutNotification(let target):
            return jumpToLatestUnread(nil, nil, target)
        }
    }

    private func markFocusedNotificationAsOldestUnread(preferredWindowToken: AnyObject?) -> MarkResult? {
        // Mirrors `guard let notificationStore, let target = focusedNotificationTarget(...)`.
        guard resolver.hasNotificationStore,
              let target = resolver.focusedTarget(preferredWindowToken: preferredWindowToken) else {
            return nil
        }
        switch target {
        case .windowDock(let dockTarget):
            return markFocusedWindowDockAsOldestUnread(dockTarget)
        case .workspace(let tabId, let surfaceId):
            return markFocusedWorkspaceAsOldestUnread(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private func markFocusedWindowDockAsOldestUnread(_ target: WindowDockUnreadTarget) -> MarkResult {
        if let notificationId = resolver.markLatestWindowDockNotificationAsOldestUnread(target) {
            return .deferredNotification(
                id: notificationId,
                windowDockTarget: target
            )
        }
        if !resolver.windowDockSurfaceIsUnread(target) {
            resolver.markWindowDockSurfaceUnread(target)
        }
        return .markedWindowDockWithoutNotification(target)
    }

    private func markFocusedWorkspaceAsOldestUnread(tabId: UUID, surfaceId: UUID?) -> MarkResult {
        if let notificationId = resolver.markLatestNotificationAsOldestUnread(
            forTabId: tabId,
            surfaceId: surfaceId
        ) {
            return .deferredNotification(
                id: notificationId,
                windowDockTarget: nil
            )
        }
        if let panel = resolver.focusedPanel(forTabId: tabId, surfaceId: surfaceId) {
            let panelAlreadyUnread =
                resolver.panelIsManualUnread(panel) ||
                resolver.panelHasRestoredUnread(panel) ||
                resolver.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: panel.panelId)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: tabId) &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            if !panelAlreadyUnread &&
                !resolver.storeHasManualUnread(forTabId: tabId) &&
                !hasWorkspaceOnlyRestoredUnread {
                resolver.markPanelUnread(panel)
            }
        } else if !resolver.workspaceIsUnread(forTabId: tabId) {
            resolver.storeMarkUnread(forTabId: tabId)
        }
        return .markedWorkspaceWithoutNotification(tabId)
    }
}
