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
        guard let panelId = host?.focusedPanelId(in: workspaceId) else { return }
        dismissPanelNotificationOnFocus(workspaceId: workspaceId, panelId: panelId, context: context)
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
        guard host?.selectedWorkspaceId == workspaceId else { return }
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
        guard host.selectedWorkspaceId == workspaceId else { return false }
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
        guard host.hasNotificationStore else { return false }
        guard host.storeHasDismissibleActivity(workspaceId: workspaceId) else { return false }
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
        let canDismissManualUnreadIndicator = context.canDismissManualUnreadIndicator &&
            (hasManualPanelUnread || hasManualWorkspaceUnread)
        let canDismissRestoredUnreadIndicator = context.canDismissRestoredUnreadIndicator &&
            (hasRestoredPanelUnread || hasRestoredWorkspaceUnread)
        let canDismissUnreadIndicator = canDismissManualUnreadIndicator || canDismissRestoredUnreadIndicator
        let hasUnreadNotification: Bool
        let hasFocusedIndicator: Bool
        if notificationSurfaceIds.isEmpty {
            hasUnreadNotification = host.storeHasUnreadNotification(workspaceId: workspaceId, surfaceId: nil)
            hasFocusedIndicator = host.storeHasVisibleNotificationIndicator(workspaceId: workspaceId, surfaceId: nil)
        } else {
            hasUnreadNotification = notificationSurfaceIds.contains {
                host.storeHasUnreadNotification(workspaceId: workspaceId, surfaceId: $0)
            }
            hasFocusedIndicator = notificationSurfaceIds.contains {
                host.storeHasVisibleNotificationIndicator(workspaceId: workspaceId, surfaceId: $0)
            }
        }
        guard hasUnreadNotification || hasFocusedIndicator || canDismissUnreadIndicator else { return false }
        if hasUnreadNotification {
            if notificationSurfaceIds.isEmpty {
                host.storeMarkRead(workspaceId: workspaceId, surfaceId: nil)
            } else {
                for surfaceId in notificationSurfaceIds {
                    host.storeMarkRead(workspaceId: workspaceId, surfaceId: surfaceId)
                }
            }
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
