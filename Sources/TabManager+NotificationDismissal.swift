import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Notification Dismissal
extension TabManager {
    enum NotificationDismissalContext: Sendable {
        case activeFocus
        case explicitWorkspaceResume
        case directInteraction
        case terminalInteraction

        var requiresActiveApp: Bool {
            switch self {
            case .activeFocus, .explicitWorkspaceResume:
                return true
            case .directInteraction, .terminalInteraction:
                return false
            }
        }

        var canDismissManualUnreadIndicator: Bool {
            self == .terminalInteraction
        }

        // Generic active focus can be produced by restore/programmatic selection.
        // Keep this exhaustive so any future context must make an explicit
        // restored-unread policy decision.
        var canDismissRestoredUnreadIndicator: Bool {
            switch self {
            case .activeFocus:
                return false
            case .explicitWorkspaceResume, .directInteraction, .terminalInteraction:
                return true
            }
        }
    }

    func dismissFocusedPanelNotificationIfActive(
        tabId: UUID,
        context: NotificationDismissalContext = .activeFocus
    ) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard let panelId = focusedPanelId(for: tabId) else { return }
        dismissPanelNotificationOnFocus(tabId: tabId, panelId: panelId, context: context)
    }

    func dismissPanelNotificationOnFocus(tabId: UUID, panelId: UUID, explicitFocusIntent: Bool) {
        dismissPanelNotificationOnFocus(
            tabId: tabId,
            panelId: panelId,
            context: explicitFocusIntent ? .directInteraction : .activeFocus
        )
    }

    func dismissPanelNotificationOnFocus(
        tabId: UUID,
        panelId: UUID,
        context: NotificationDismissalContext
    ) {
        guard selectedTabId == tabId else { return }
        guard !suppressFocusFlash else { return }
        _ = dismissNotification(
            tabId: tabId,
            surfaceId: panelId,
            context: context
        )
    }

    @discardableResult
    func dismissNotificationOnDirectInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        dismissNotification(tabId: tabId, surfaceId: surfaceId, context: .directInteraction)
    }

    @discardableResult
    func dismissNotificationOnTerminalInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        dismissNotification(tabId: tabId, surfaceId: surfaceId, context: .terminalInteraction)
    }

    @discardableResult
    func dismissNotification(
        tabId: UUID,
        surfaceId: UUID?,
        context: NotificationDismissalContext
    ) -> Bool {
        guard selectedTabId == tabId else { return false }
        if context.requiresActiveApp {
            guard AppFocusState.isAppActive() else { return false }
        }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return false }
        let workspace = tabs.first(where: { $0.id == tabId })
        let targetPanelId = surfaceId.flatMap { surfaceOrPanelId in
            workspace.flatMap { panelId(forSurfaceOrPanelId: surfaceOrPanelId, in: $0) }
        }
        var notificationSurfaceIds: [UUID] = []
        if let surfaceId {
            notificationSurfaceIds.append(surfaceId)
        }
        if let targetPanelId, !notificationSurfaceIds.contains(targetPanelId) {
            notificationSurfaceIds.append(targetPanelId)
        }
        let hasManualPanelUnread = targetPanelId.map { workspace?.manualUnreadPanelIds.contains($0) ?? false } ?? false
        let hasRestoredPanelUnread = targetPanelId.map { workspace?.hasRestoredUnreadIndicator(panelId: $0) ?? false } ?? false
        let hasManualWorkspaceUnread = notificationStore.hasManualUnread(forTabId: tabId)
        let hasRestoredWorkspaceUnread = notificationStore.hasRestoredUnreadIndicator(forTabId: tabId)
        let canDismissManualUnreadIndicator = context.canDismissManualUnreadIndicator &&
            (hasManualPanelUnread || hasManualWorkspaceUnread)
        let canDismissRestoredUnreadIndicator = context.canDismissRestoredUnreadIndicator &&
            (hasRestoredPanelUnread || hasRestoredWorkspaceUnread)
        let canDismissUnreadIndicator = canDismissManualUnreadIndicator || canDismissRestoredUnreadIndicator
        let hasUnreadNotification: Bool
        let hasFocusedIndicator: Bool
        if notificationSurfaceIds.isEmpty {
            hasUnreadNotification = notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: nil)
            hasFocusedIndicator = notificationStore.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: nil)
        } else {
            hasUnreadNotification = notificationSurfaceIds.contains {
                notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: $0)
            }
            hasFocusedIndicator = notificationSurfaceIds.contains {
                notificationStore.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: $0)
            }
        }
        guard hasUnreadNotification || hasFocusedIndicator || canDismissUnreadIndicator else { return false }
        if hasUnreadNotification {
            if notificationSurfaceIds.isEmpty {
                notificationStore.markRead(forTabId: tabId, surfaceId: nil)
            } else {
                for surfaceId in notificationSurfaceIds {
                    notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
                }
            }
        }
        var didDismissUnreadIndicator = false
        if context.canDismissManualUnreadIndicator {
            if let targetPanelId, hasManualPanelUnread {
                workspace?.clearManualUnread(panelId: targetPanelId)
                didDismissUnreadIndicator = true
            }
            if hasManualWorkspaceUnread {
                didDismissUnreadIndicator = notificationStore.clearManualUnread(forTabId: tabId) || didDismissUnreadIndicator
            }
        }
        if context.canDismissRestoredUnreadIndicator {
            if let targetPanelId, hasRestoredPanelUnread {
                workspace?.clearRestoredUnreadIndicator(panelId: targetPanelId)
                didDismissUnreadIndicator = true
            }
            if hasRestoredWorkspaceUnread {
                didDismissUnreadIndicator =
                    notificationStore.clearRestoredUnreadIndicator(forTabId: tabId) || didDismissUnreadIndicator
            }
        }
        if notificationSurfaceIds.isEmpty {
            notificationStore.clearFocusedReadIndicator(forTabId: tabId, surfaceId: nil)
        } else {
            for surfaceId in notificationSurfaceIds {
                notificationStore.clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
            }
        }
        if let targetPanelId,
           let workspace {
            if hasUnreadNotification || hasFocusedIndicator {
                workspace.triggerNotificationDismissFlash(panelId: targetPanelId)
            } else if didDismissUnreadIndicator {
                workspace.triggerUnreadIndicatorDismissFlash(panelId: targetPanelId)
            }
        }
        return true
    }

}
