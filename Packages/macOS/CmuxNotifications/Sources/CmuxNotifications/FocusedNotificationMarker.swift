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
    private let jumpToLatestUnread: (_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) -> UUID?

    /// Creates a focused-notification marker driven by the injected resolver
    /// and jump closure.
    public init(
        resolver: any FocusedNotificationResolving,
        jumpToLatestUnread: @escaping (_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) -> UUID?
    ) {
        self.resolver = resolver
        self.jumpToLatestUnread = jumpToLatestUnread
    }

    /// The result of marking the focused notification oldest-unread, mirroring
    /// the app-target `FocusedNotificationMarkResult`.
    private enum MarkResult {
        case deferredNotification(UUID)
        case markedWorkspaceWithoutNotification(UUID)
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
        if let panel = resolver.focusedPanel(forTabId: target.tabId, surfaceId: target.surfaceId) {
            let focusedPanelHasRestoredUnread = resolver.panelHasRestoredUnread(panel)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: target.tabId) &&
                !focusedPanelHasRestoredUnread &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            if resolver.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: nil) ||
                hasWorkspaceOnlyRestoredUnread {
                resolver.storeMarkRead(forTabId: target.tabId)
                return true
            }
            let hasWorkspaceManualUnreadOnPanel =
                resolver.storeHasManualUnread(forTabId: target.tabId) &&
                resolver.panelIsRepresentativeForWorkspaceManualUnread(panel)
            let isPanelUnread =
                resolver.panelIsManualUnread(panel) ||
                focusedPanelHasRestoredUnread ||
                resolver.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: panel.panelId) ||
                hasWorkspaceManualUnreadOnPanel
            if isPanelUnread {
                resolver.markPanelRead(panel)
                if hasWorkspaceManualUnreadOnPanel {
                    resolver.storeClearManualUnread(forTabId: target.tabId)
                }
                return true
            }
            resolver.markPanelUnread(panel)
            return true
        }
        if resolver.workspaceIsUnread(forTabId: target.tabId) {
            resolver.storeMarkRead(forTabId: target.tabId)
            return true
        }
        resolver.storeMarkUnread(forTabId: target.tabId)
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
        case .deferredNotification(let notificationId):
            return jumpToLatestUnread(notificationId, nil)
        case .markedWorkspaceWithoutNotification(let tabId):
            return jumpToLatestUnread(nil, tabId)
        }
    }

    private func markFocusedNotificationAsOldestUnread(preferredWindowToken: AnyObject?) -> MarkResult? {
        // Mirrors `guard let notificationStore, let target = focusedNotificationTarget(...)`.
        guard resolver.hasNotificationStore,
              let target = resolver.focusedTarget(preferredWindowToken: preferredWindowToken) else {
            return nil
        }
        if let notificationId = resolver.markLatestNotificationAsOldestUnread(
            forTabId: target.tabId,
            surfaceId: target.surfaceId
        ) {
            return .deferredNotification(notificationId)
        }
        if let panel = resolver.focusedPanel(forTabId: target.tabId, surfaceId: target.surfaceId) {
            let panelAlreadyUnread =
                resolver.panelIsManualUnread(panel) ||
                resolver.panelHasRestoredUnread(panel) ||
                resolver.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: panel.panelId)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: target.tabId) &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            if !panelAlreadyUnread &&
                !resolver.storeHasManualUnread(forTabId: target.tabId) &&
                !hasWorkspaceOnlyRestoredUnread {
                resolver.markPanelUnread(panel)
            }
        } else if !resolver.workspaceIsUnread(forTabId: target.tabId) {
            resolver.storeMarkUnread(forTabId: target.tabId)
        }
        return .markedWorkspaceWithoutNotification(target.tabId)
    }
}
