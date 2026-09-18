public import Foundation
import Observation

/// Per-window (per-panel) notification-dismissal sub-model: the dismissal
/// decision flow TabManager used to run inline, plus its two pieces of
/// selection-adjacent state (`pendingSelectedTabNotificationDismissContext`
/// and the `suppressFocusFlash` latch).
///
/// `@MainActor` because every entry point is a MainActor UI path (selection
/// didSet side effects, the surface-focus observer, terminal keystrokes,
/// sidebar clicks) — state lives where its callers live. Reads and writes
/// go through ``NotificationDismissalHosting`` synchronously inside one
/// turn, preserving the legacy interleavings exactly.
@MainActor
@Observable
public final class NotificationDismissalModel: NotificationDismissing {
    // The window-side seam; set once via attach(host:). Weak: the host
    // (the per-window TabManager) owns the model.
    private(set) weak var host: (any NotificationDismissalHosting)?

    private var suppressFocusFlash = false
    private var pendingSelectedWorkspaceContext: NotificationDismissalContext?

    /// Creates a detached model; call ``attach(host:)`` before use.
    public init() {}

    public func attach(host: any NotificationDismissalHosting) {
        self.host = host
    }

    public var suppressesFocusFlash: Bool {
        suppressFocusFlash
    }

    public func setSuppressesFocusFlash(_ suppresses: Bool) {
        suppressFocusFlash = suppresses
    }

    public func setPendingSelectionContext(_ context: NotificationDismissalContext?) {
        pendingSelectedWorkspaceContext = context
    }

    public func takePendingSelectionContext() -> NotificationDismissalContext? {
        let context = pendingSelectedWorkspaceContext
        pendingSelectedWorkspaceContext = nil
        return context
    }

    public func dismissFocusedPanelNotificationIfActive(
        workspaceId: UUID,
        context: NotificationDismissalContext
    ) {
        // Consume the latch first: even a suppressed call clears it,
        // matching the legacy read-then-reset sequence.
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard let surfaceId = host?.focusedSurfaceId(in: workspaceId) else { return }
        dismissPanelNotificationOnFocus(workspaceId: workspaceId, panelId: surfaceId, context: context)
    }

    public func dismissPanelNotificationOnFocus(
        workspaceId: UUID,
        panelId: UUID,
        explicitFocusIntent: Bool
    ) {
        dismissPanelNotificationOnFocus(
            workspaceId: workspaceId,
            panelId: panelId,
            context: explicitFocusIntent ? .directInteraction : .activeFocus
        )
    }

    private func dismissPanelNotificationOnFocus(
        workspaceId: UUID,
        panelId: UUID,
        context: NotificationDismissalContext
    ) {
        guard !suppressFocusFlash else { return }
        _ = dismissNotification(
            workspaceId: workspaceId,
            surfaceId: panelId,
            context: context
        )
    }

    @discardableResult
    public func dismissNotificationOnDirectInteraction(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        dismissNotification(workspaceId: workspaceId, surfaceId: surfaceId, context: .directInteraction)
    }

    @discardableResult
    public func dismissNotificationOnTerminalInteraction(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        dismissNotification(workspaceId: workspaceId, surfaceId: surfaceId, context: .terminalInteraction)
    }

    @discardableResult
    public func dismissNotification(
        workspaceId: UUID,
        surfaceId: UUID?,
        context: NotificationDismissalContext
    ) -> Bool {
        guard let host else { return false }
        guard host.hasNotificationStore else { return false }
        guard host.storeHasDismissibleState(workspaceId: workspaceId) ||
            host.workspaceHasDismissiblePanelState(workspaceId: workspaceId) else { return false }
        guard host.isNotificationTargetSelected(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        ) else { return false }
        if context.requiresActiveApp {
            guard host.isAppActive else { return false }
            // Opt-in (`notifications.suppressOnlyFocusedSurface`): narrow the
            // implicit, workspace-visibility-driven auto-withdraw to the exact
            // focused surface. Without this, a banner delivered for a
            // non-focused surface in the now-visible workspace could be swept
            // along; the delivery gate (`shouldSuppressExternalDelivery`)
            // already keys on the focused surface, and this makes the withdraw
            // side match it. Nesting under `requiresActiveApp` keeps it off the
            // explicit per-surface paths (direct click, terminal typing) — so
            // the setting is never read on the per-keystroke dismiss — and a
            // `nil` `surfaceId` (workspace-level dismissal) stays broad. See
            // issue #6601.
            if host.suppressOnlyFocusedSurface,
               let surfaceId,
               host.focusedSurfaceId(in: workspaceId) != surfaceId {
                return false
            }
        }
        let targetPanelId = surfaceId.flatMap {
            host.panelId(forSurfaceOrPanelId: $0, in: workspaceId)
        }
        var notificationSurfaceIds: [UUID] = []
        if let surfaceId {
            notificationSurfaceIds.append(surfaceId)
        }
        if let targetPanelId, !notificationSurfaceIds.contains(targetPanelId) {
            notificationSurfaceIds.append(targetPanelId)
        }
        let hasManualPanelUnread = targetPanelId.map {
            host.workspaceHasManualPanelUnread(workspaceId: workspaceId, panelId: $0)
        } ?? false
        let hasRestoredPanelUnread = targetPanelId.map {
            host.workspaceHasRestoredPanelUnread(workspaceId: workspaceId, panelId: $0)
        } ?? false
        let hasManualWorkspaceUnread = host.storeHasManualUnread(workspaceId: workspaceId)
        let hasRestoredWorkspaceUnread = host.storeHasRestoredUnreadIndicator(workspaceId: workspaceId)
        let hasUnreadNotification: Bool
        let hasPendingNotification: Bool
        let hasFocusedIndicator: Bool
        if notificationSurfaceIds.isEmpty {
            hasUnreadNotification = host.storeHasUnreadNotification(workspaceId: workspaceId, surfaceId: nil)
            hasPendingNotification = host.storeHasPendingNotification(workspaceId: workspaceId, surfaceId: nil)
            hasFocusedIndicator = host.storeHasVisibleNotificationIndicator(workspaceId: workspaceId, surfaceId: nil)
        } else {
            hasUnreadNotification = notificationSurfaceIds.contains {
                host.storeHasUnreadNotification(workspaceId: workspaceId, surfaceId: $0)
            }
            hasPendingNotification = notificationSurfaceIds.contains {
                host.storeHasPendingNotification(workspaceId: workspaceId, surfaceId: $0)
            }
            hasFocusedIndicator = notificationSurfaceIds.contains {
                host.storeHasVisibleNotificationIndicator(workspaceId: workspaceId, surfaceId: $0)
            }
        }
        // A notification recorded against the workspace itself, with no surface
        // and no panel (cmux's own memory-pressure alert is one), matches no
        // surface-scoped mark-read, so focusing the workspace left it unread and
        // its sidebar count only cleared through an explicit "Mark Workspace as
        // Read". Sweep it together with the dismissal of the workspace's focused
        // surface, the moment the workspace is in front of the user; the other
        // surfaces in the workspace keep their own unread state. See issue
        // #12387.
        let hasWorkspaceLevelUnreadNotification = !notificationSurfaceIds.isEmpty &&
            host.storeHasUnreadNotification(workspaceId: workspaceId, surfaceId: nil) &&
            (host.focusedSurfaceId(in: workspaceId)
                .map { notificationSurfaceIds.contains($0) } ?? false)
        let manualStoreSurfaceIds = notificationSurfaceIds.filter {
            host.storeHasManualUnread(workspaceId: workspaceId, surfaceId: $0)
        }
        let canDismissManualUnreadIndicator = context.canDismissManualUnreadIndicator &&
            (hasManualPanelUnread || hasManualWorkspaceUnread || !manualStoreSurfaceIds.isEmpty)
        let canDismissRestoredUnreadIndicator = context.canDismissRestoredUnreadIndicator &&
            (hasRestoredPanelUnread || hasRestoredWorkspaceUnread)
        let canDismissUnreadIndicator = canDismissManualUnreadIndicator || canDismissRestoredUnreadIndicator
        guard hasUnreadNotification || hasPendingNotification || hasFocusedIndicator ||
            hasWorkspaceLevelUnreadNotification || canDismissUnreadIndicator else {
            return false
        }
        if hasUnreadNotification || hasPendingNotification {
            if notificationSurfaceIds.isEmpty {
                host.storeMarkRead(workspaceId: workspaceId, surfaceId: nil)
            } else {
                for surfaceId in notificationSurfaceIds {
                    host.storeMarkRead(workspaceId: workspaceId, surfaceId: surfaceId)
                }
            }
        }
        if hasWorkspaceLevelUnreadNotification {
            host.storeMarkWorkspaceLevelNotificationsRead(workspaceId: workspaceId)
        }
        var didDismissUnreadIndicator = false
        if context.canDismissManualUnreadIndicator {
            if let targetPanelId, hasManualPanelUnread {
                host.workspaceClearManualUnread(workspaceId: workspaceId, panelId: targetPanelId)
                didDismissUnreadIndicator = true
            }
            if hasManualWorkspaceUnread {
                didDismissUnreadIndicator = host.storeClearManualUnread(workspaceId: workspaceId) || didDismissUnreadIndicator
            }
            for surfaceId in manualStoreSurfaceIds {
                didDismissUnreadIndicator = host.storeClearManualUnread(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                ) || didDismissUnreadIndicator
            }
        }
        if context.canDismissRestoredUnreadIndicator {
            if let targetPanelId, hasRestoredPanelUnread {
                host.workspaceClearRestoredUnreadIndicator(workspaceId: workspaceId, panelId: targetPanelId)
                didDismissUnreadIndicator = true
            }
            if hasRestoredWorkspaceUnread {
                didDismissUnreadIndicator =
                    host.storeClearRestoredUnreadIndicator(workspaceId: workspaceId) || didDismissUnreadIndicator
            }
        }
        if notificationSurfaceIds.isEmpty {
            host.storeClearFocusedReadIndicator(workspaceId: workspaceId, surfaceId: nil)
        } else {
            for surfaceId in notificationSurfaceIds {
                host.storeClearFocusedReadIndicator(workspaceId: workspaceId, surfaceId: surfaceId)
            }
        }
        if let targetPanelId {
            if hasUnreadNotification || hasFocusedIndicator {
                host.workspaceTriggerNotificationDismissFlash(workspaceId: workspaceId, panelId: targetPanelId)
            } else if didDismissUnreadIndicator {
                host.workspaceTriggerUnreadIndicatorDismissFlash(workspaceId: workspaceId, panelId: targetPanelId)
            }
        }
        return true
    }
}
