import AppKit
import CMUXAgentLaunch
import CmuxFeedUI
import CmuxNotifications
import Foundation

/// App-side adapter for notification delivery seams. The delivery coordinator
/// stores this object strongly; the adapter keeps only a weak owner reference so
/// `AppDelegate -> NotificationDeliveryCoordinator -> adapter -> AppDelegate`
/// cannot become a retain cycle.
@MainActor
final class NotificationDeliverySeamAdapter: NotificationFeedReplying, NotificationApplicationActivating {
    weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
    }

    func deliverReply(requestId: String, decision: NotificationFeedDecision) {
        owner?.notificationDeliveryDeliverFeedReply(requestId: requestId, decision: decision)
    }

    func permissionCapabilities(requestId: String) -> NotificationFeedPermissionCapabilities? {
        owner?.notificationDeliveryPermissionCapabilities(requestId: requestId)
    }

    func activateApplication() {
        owner?.notificationDeliveryActivateApplication()
    }
}

extension AppDelegate {
    func notificationDeliveryDeliverFeedReply(requestId: String, decision: NotificationFeedDecision) {
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: decision.workstreamDecision
        )
    }

    func notificationDeliveryPermissionCapabilities(requestId: String) -> NotificationFeedPermissionCapabilities? {
        guard let item = FeedCoordinator.shared.socketRouter.snapshot(pendingOnly: false).reversed().first(where: { item in
            guard case .permissionRequest(let itemRequestId, _, _, _) = item.payload else { return false }
            return itemRequestId == requestId
        }) else {
            return nil
        }
        guard case .permissionRequest(_, _, let toolInputJSON, _) = item.payload else {
            return nil
        }

        return NotificationFeedPermissionCapabilities(
            supportsOnce: FeedPermissionActionPolicy.supportsOncePermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            ),
            supportsAlways: FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            ),
            supportsAll: FeedPermissionActionPolicy.supportsAllPermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            )
        )
    }

    func notificationDeliveryActivateApplication() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
