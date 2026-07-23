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
    private let terminalReplying: any NotificationTerminalReplying
    private let feedReplying: any NotificationFeedReplying
    private let applicationActivation: any NotificationApplicationActivating
    private let terminalIdentifiers: TerminalNotificationDeliveryIdentifiers
    private let actionTitles: NotificationDeliveryActionTitles

    /// Creates a notification delivery coordinator with all OS, terminal, Feed,
    /// and activation side effects supplied through injected seams.
    public init(
        center: any UserNotificationCenterConfiguring,
        terminalNavigation: any NotificationDeliveryTerminalNavigating,
        terminalReplying: any NotificationTerminalReplying,
        feedReplying: any NotificationFeedReplying,
        applicationActivation: any NotificationApplicationActivating,
        terminalIdentifiers: TerminalNotificationDeliveryIdentifiers,
        actionTitles: NotificationDeliveryActionTitles
    ) {
        self.center = center
        self.terminalNavigation = terminalNavigation
        self.terminalReplying = terminalReplying
        self.feedReplying = feedReplying
        self.applicationActivation = applicationActivation
        self.terminalIdentifiers = terminalIdentifiers
        self.actionTitles = actionTitles
    }

    /// Installs every terminal and Feed notification category, then assigns the
    /// `UNUserNotificationCenter` delegate.
    public func configureUserNotifications(delegate: any UNUserNotificationCenterDelegate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = await center.currentNotificationCategories()
            center.setNotificationCategories(current.union(notificationCategories()))
        }
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
        let terminalReplyAction = UNTextInputNotificationAction(
            identifier: terminalIdentifiers.replyActionIdentifier,
            title: actionTitles.reply,
            options: [],
            textInputButtonTitle: actionTitles.replySend,
            textInputPlaceholder: actionTitles.replyPlaceholder
        )
        let terminalTextReplyCategory = UNNotificationCategory(
            identifier: terminalIdentifiers.textReplyCategoryIdentifier,
            actions: [terminalReplyAction, terminalShowAction],
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
                UNTextInputNotificationAction(
                    identifier: "feed.exit_plan.revise",
                    title: actionTitles.feedExitPlanRevise,
                    options: [],
                    textInputButtonTitle: actionTitles.replySend,
                    textInputPlaceholder: actionTitles.replyPlaceholder
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

        return Set([terminalCategory, terminalTextReplyCategory, exitPlanCategory, questionCategory] + permissionCategories)
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
           || categoryId.hasPrefix("CMUXFeedQuestion.")
        else { return false }

        guard let requestId = response.userInfo["requestId"] as? String else {
            if categoryId.hasPrefix("CMUXFeedQuestion.") {
                applicationActivation.activateApplication()
            }
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
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.ultraplan, feedback: nil))
        case "feed.exit_plan.bypassPermissions":
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.bypassPermissions, feedback: nil))
        case "feed.exit_plan.autoAccept":
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.autoAccept, feedback: nil))
        case "feed.exit_plan.manual":
            feedReplying.deliverReply(requestId: requestId, decision: .exitPlan(.manual, feedback: nil))
        case "feed.exit_plan.revise":
            let feedback = response.userText?.trimmingCharacters(in: .whitespacesAndNewlines)
            feedReplying.deliverReply(
                requestId: requestId,
                decision: .exitPlan(.manual, feedback: feedback?.isEmpty == false ? feedback : nil)
            )
        case let action where action.hasPrefix("feed.question.option."):
            guard let index = Int(action.dropFirst("feed.question.option.".count)),
                  let optionIds = response.userInfo["questionOptionIds"] as? [String],
                  optionIds.indices.contains(index) else {
                applicationActivation.activateApplication()
                return true
            }
            feedReplying.deliverReply(requestId: requestId, decision: .question(selections: [optionIds[index]]))
        case "feed.question.other":
            guard let text = response.userText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                applicationActivation.activateApplication()
                return true
            }
            feedReplying.deliverReply(requestId: requestId, decision: .question(selections: [text]))
        case "feed.question.open":
            applicationActivation.activateApplication()
        case UNNotificationDismissActionIdentifier,
             UNNotificationDefaultActionIdentifier:
            applicationActivation.activateApplication()
        default:
            if categoryId.hasPrefix("CMUXFeedQuestion.") {
                applicationActivation.activateApplication()
            }
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
        case terminalIdentifiers.replyActionIdentifier:
            guard let target = terminalTarget(response) else { return }
            let text = response.userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                openTerminalNotification(response, target: target)
                return
            }
            let didSend = terminalReplying.sendReply(
                text: text,
                tabId: target.tabId,
                surfaceId: target.surfaceId,
                retargetsToLiveSurfaceOwner: target.retargetsToLiveSurfaceOwner
            )
            if didSend, let notificationId = notificationId(response) {
                terminalNavigation.markNotificationRead(id: notificationId)
            } else if !didSend {
                openTerminalNotification(response, target: target)
            }
        case UNNotificationDefaultActionIdentifier, terminalIdentifiers.showActionIdentifier:
            guard let target = terminalTarget(response) else { return }
            openTerminalNotification(response, target: target)
        case UNNotificationDismissActionIdentifier:
            if let notificationId = notificationId(response) {
                terminalNavigation.markNotificationRead(id: notificationId)
            }
        default:
            break
        }
    }

    private func openTerminalNotification(
        _ response: NotificationDeliveryResponse,
        target: (tabId: UUID, surfaceId: UUID?, retargetsToLiveSurfaceOwner: Bool)
    ) {
            let notificationId = notificationId(response)
            if let clickAction = NotificationNavClickAction(userInfo: response.userInfo) {
                let didPerform = terminalNavigation.performClickAction(clickAction)
                if didPerform, let notificationId {
                    terminalNavigation.markNotificationRead(id: notificationId)
                }
                return
            }
            if let notificationId {
                _ = terminalNavigation.openNotification(
                    id: notificationId,
                    fallbackTabId: target.tabId,
                    fallbackSurfaceId: target.surfaceId,
                    fallbackRetargetsToLiveSurfaceOwner: target.retargetsToLiveSurfaceOwner
                )
            } else {
                _ = terminalNavigation.open(tabId: target.tabId, surfaceId: target.surfaceId, notificationId: nil)
            }
    }

    private func terminalTarget(
        _ response: NotificationDeliveryResponse
    ) -> (tabId: UUID, surfaceId: UUID?, retargetsToLiveSurfaceOwner: Bool)? {
        guard let tabIdString = response.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else { return nil }
        let surfaceId = (response.userInfo["surfaceId"] as? String).flatMap(UUID.init(uuidString:))
        let retargets = response.userInfo[
            terminalIdentifiers.retargetsToLiveSurfaceOwnerUserInfoKey
        ] as? Bool ?? true
        return (tabId, surfaceId, retargets)
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
