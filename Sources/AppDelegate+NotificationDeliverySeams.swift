import AppKit
import CMUXAgentLaunch
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
            decision: Self.workstreamDecision(from: decision)
        )
    }

    func notificationDeliveryPermissionCapabilities(requestId: String) -> NotificationFeedPermissionCapabilities? {
        guard let item = FeedCoordinator.shared.snapshot(pendingOnly: false).reversed().first(where: { item in
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

    private static func workstreamDecision(from decision: NotificationFeedDecision) -> WorkstreamDecision {
        switch decision {
        case .permission(let mode):
            return .permission(workstreamPermissionMode(from: mode))
        case .exitPlan(let mode):
            return .exitPlan(workstreamExitPlanMode(from: mode))
        }
    }

    private static func workstreamPermissionMode(
        from mode: NotificationFeedPermissionMode
    ) -> WorkstreamPermissionMode {
        switch mode {
        case .once:
            return .once
        case .always:
            return .always
        case .all:
            return .all
        case .bypass:
            return .bypass
        case .deny:
            return .deny
        }
    }

    private static func workstreamExitPlanMode(from mode: NotificationFeedExitPlanMode) -> WorkstreamExitPlanMode {
        switch mode {
        case .ultraplan:
            return .ultraplan
        case .bypassPermissions:
            return .bypassPermissions
        case .autoAccept:
            return .autoAccept
        case .manual:
            return .manual
        case .deny:
            return .deny
        }
    }
}
