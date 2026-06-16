public import Foundation
import Observation
public import UserNotifications

/// Coordinates OS notification category installation, foreground presentation
/// choices, and response delivery for terminal and Feed notifications.
///
/// The coordinator owns the notification delivery/response domain. System
/// access is inverted through ``UserNotificationCenterConfiguring``. Terminal
/// responses route into ``NotificationNavigationCoordinator`` through
/// ``NotificationDeliveryTerminalNavigating``. Feed responses route through
/// ``NotificationFeedReplying`` and app activation through
/// ``NotificationApplicationActivating``.
@MainActor
@Observable
public final class NotificationDeliveryCoordinator {
    private let center: any UserNotificationCenterConfiguring
    private let terminalNavigation: any NotificationDeliveryTerminalNavigating
    private let feedReplying: any NotificationFeedReplying
    private let applicationActivation: any NotificationApplicationActivating
    private let terminalIdentifiers: TerminalNotificationDeliveryIdentifiers
    private let actionTitles: NotificationDeliveryActionTitles

    /// Creates a notification delivery coordinator with all OS, terminal, Feed,
    /// and activation side effects supplied through injected seams.
    public init(
        center: any UserNotificationCenterConfiguring,
        terminalNavigation: any NotificationDeliveryTerminalNavigating,
        feedReplying: any NotificationFeedReplying,
        applicationActivation: any NotificationApplicationActivating,
        terminalIdentifiers: TerminalNotificationDeliveryIdentifiers,
        actionTitles: NotificationDeliveryActionTitles
    ) {
        self.center = center
        self.terminalNavigation = terminalNavigation
        self.feedReplying = feedReplying
        self.applicationActivation = applicationActivation
        self.terminalIdentifiers = terminalIdentifiers
        self.actionTitles = actionTitles
    }

    /// Installs every terminal and Feed notification category, then assigns the
    /// `UNUserNotificationCenter` delegate.
    public func configureUserNotifications(delegate: any UNUserNotificationCenterDelegate) {
        center.setNotificationCategories(notificationCategories())
        center.setDelegate(delegate)
    }

    /// Presentation options for a notification delivered while the app is in
    /// the foreground.
    public func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        presentationOptions(notificationHasSound: notification.request.content.sound != nil)
    }

    /// Handles a notification response from `UNUserNotificationCenterDelegate`.
    public func handleNotificationResponse(_ response: UNNotificationResponse) {
        handle(NotificationDeliveryResponse(response))
    }

    func presentationOptions(notificationHasSound: Bool) -> UNNotificationPresentationOptions {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notificationHasSound {
            options.insert(.sound)
        }
        return options
    }

    func handle(_ response: NotificationDeliveryResponse) {
        if handleFeedNotificationResponse(response) {
            return
        }
        handleTerminalNotificationResponse(response)
    }

    func notificationCategories() -> Set<UNNotificationCategory> {
        let terminalShowAction = UNNotificationAction(
            identifier: terminalIdentifiers.showActionIdentifier,
            title: actionTitles.show
        )

        let terminalCategory = UNNotificationCategory(
            identifier: terminalIdentifiers.categoryIdentifier,
            actions: [terminalShowAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let permissionOnceAction = UNNotificationAction(
            identifier: "feed.permission.once",
            title: actionTitles.feedPermissionAllowOnce
        )
        let permissionAlwaysAction = UNNotificationAction(
            identifier: "feed.permission.always",
            title: actionTitles.feedPermissionAlways
        )
        let permissionAllAction = UNNotificationAction(
            identifier: "feed.permission.all",
            title: actionTitles.feedPermissionAll
        )
        let permissionDenyAction = UNNotificationAction(
            identifier: "feed.permission.deny",
            title: actionTitles.feedPermissionDeny,
            options: [.destructive]
        )
        let permissionCategories = feedPermissionNotificationCategoryIds().map { categoryId in
            var actions: [UNNotificationAction] = []
            if categoryId.contains("Once") || categoryId == "CMUXFeedPermission" {
                actions.append(permissionOnceAction)
            }
            if categoryId.contains("Always") || categoryId == "CMUXFeedPermission" {
                actions.append(permissionAlwaysAction)
            }
            if categoryId.contains("All") {
                actions.append(permissionAllAction)
            }
            actions.append(permissionDenyAction)
            return UNNotificationCategory(
                identifier: categoryId,
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
        }

        let exitPlanCategory = UNNotificationCategory(
            identifier: "CMUXFeedExitPlan",
            actions: [
                UNNotificationAction(
                    identifier: "feed.exit_plan.ultraplan",
                    title: actionTitles.feedExitPlanUltraplan
                ),
                UNNotificationAction(
                    identifier: "feed.exit_plan.manual",
                    title: actionTitles.feedExitPlanManual
                ),
                UNNotificationAction(
                    identifier: "feed.exit_plan.autoAccept",
                    title: actionTitles.feedExitPlanAutoAccept
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
        let questionCategory = UNNotificationCategory(
            identifier: "CMUXFeedQuestion",
            actions: [
                UNNotificationAction(
                    identifier: "feed.question.open",
                    title: actionTitles.feedQuestionReply,
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        return Set([terminalCategory, exitPlanCategory, questionCategory] + permissionCategories)
    }

    private func feedPermissionNotificationCategoryIds() -> [String] {
        [
            "CMUXFeedPermission",
            "CMUXFeedPermissionDeny",
            "CMUXFeedPermissionOnce",
            "CMUXFeedPermissionAlways",
            "CMUXFeedPermissionAll",
            "CMUXFeedPermissionOnceAlways",
            "CMUXFeedPermissionOnceAll",
            "CMUXFeedPermissionAlwaysAll",
            "CMUXFeedPermissionOnceAlwaysAll",
        ]
    }

    private func handleFeedNotificationResponse(_ response: NotificationDeliveryResponse) -> Bool {
        let categoryId = response.categoryIdentifier
        guard categoryId.hasPrefix("CMUXFeedPermission")
           || categoryId == "CMUXFeedExitPlan"
           || categoryId == "CMUXFeedQuestion"
        else { return false }

        guard let requestId = response.userInfo["requestId"] as? String else {
            return true
        }

        switch response.actionIdentifier {
        case "feed.permission.once":
            guard let decision = feedPermissionNotificationDecision(requestId: requestId, requestedMode: .once) else {
                return true
            }
            feedReplying.deliverReply(requestId: requestId, decision: decision)
        case "feed.permission.always":
            guard let decision = feedPermissionNotificationDecision(requestId: requestId, requestedMode: .always) else {
                return true
            }
            feedReplying.deliverReply(requestId: requestId, decision: decision)
        case "feed.permission.all":
            guard let decision = feedPermissionNotificationDecision(requestId: requestId, requestedMode: .all) else {
                return true
            }
            feedReplying.deliverReply(requestId: requestId, decision: decision)
        case "feed.permission.deny":
            feedReplying.deliverReply(requestId: requestId, decision: .permission(.deny))
        case "feed.exit_plan.ultraplan":
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.ultraplan))
        case "feed.exit_plan.bypassPermissions":
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.bypassPermissions))
        case "feed.exit_plan.autoAccept":
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.autoAccept))
        case "feed.exit_plan.manual":
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.manual))
        case "feed.question.open":
            applicationActivation.activateApplication()
        case UNNotificationDismissActionIdentifier,
             UNNotificationDefaultActionIdentifier:
            applicationActivation.activateApplication()
        default:
            break
        }
        return true
    }

    private func feedPermissionNotificationDecision(
        requestId: String,
        requestedMode: NotificationFeedPermissionMode
    ) -> NotificationFeedDecision? {
        guard let capabilities = feedReplying.permissionCapabilities(requestId: requestId) else {
            return .permission(requestedMode)
        }

        switch requestedMode {
        case .once:
            guard capabilities.supportsOnce else {
                return nil
            }
            return .permission(.once)
        case .always:
            if capabilities.supportsAlways {
                return .permission(.always)
            }
            if capabilities.supportsOnce {
                return .permission(.once)
            }
            return nil
        case .all:
            guard capabilities.supportsAll else {
                return nil
            }
            return .permission(.all)
        default:
            return .permission(requestedMode)
        }
    }

    private func handleTerminalNotificationResponse(_ response: NotificationDeliveryResponse) {
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, terminalIdentifiers.showActionIdentifier:
            guard let tabIdString = response.userInfo["tabId"] as? String,
                  let tabId = UUID(uuidString: tabIdString) else {
                return
            }
            let surfaceId: UUID? = {
                guard let surfaceIdString = response.userInfo["surfaceId"] as? String else {
                    return nil
                }
                return UUID(uuidString: surfaceIdString)
            }()
            let notificationId = notificationId(response)
            if let clickAction = NotificationNavClickAction(userInfo: response.userInfo) {
                let didPerform = terminalNavigation.performClickAction(clickAction)
                if didPerform, let notificationId {
                    terminalNavigation.markNotificationRead(id: notificationId)
                }
                return
            }
            _ = terminalNavigation.open(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
        case UNNotificationDismissActionIdentifier:
            if let notificationId = notificationId(response) {
                terminalNavigation.markNotificationRead(id: notificationId)
            }
        default:
            break
        }
    }

    private func notificationId(_ response: NotificationDeliveryResponse) -> UUID? {
        if let id = UUID(uuidString: response.requestIdentifier) {
            return id
        }
        if let idString = response.userInfo["notificationId"] as? String,
           let id = UUID(uuidString: idString) {
            return id
        }
        return nil
    }
}
