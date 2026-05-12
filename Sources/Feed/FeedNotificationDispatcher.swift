import AppKit
import CMUXWorkstream
import Foundation
import UserNotifications

// MARK: - Native notification banner

enum FeedNotificationDispatcher {
    struct ActiveTerminalTarget: Equatable, Sendable {
        let workspaceId: UUID
        let surfaceId: UUID
    }

    struct FrontmostContext: Sendable {
        let isAppFrontmost: Bool
        let activeTerminalTarget: ActiveTerminalTarget?
    }

    static func post(
        event: WorkstreamEvent,
        requestId: String
    ) {
        // Hook threads block waiting for the user decision; resolve the
        // notification target off-thread so disk-backed session lookup
        // does not add latency before that wait begins.
        Task.detached(priority: .utility) {
            let notificationTarget = resolvedTarget(for: event)
            await deliverIfNeeded(
                event: event,
                requestId: requestId,
                notificationTarget: notificationTarget
            )
        }
    }

    static func shouldSuppress(
        notificationTarget: ActiveTerminalTarget?,
        frontmostContext: FrontmostContext
    ) -> Bool {
        guard frontmostContext.isAppFrontmost,
              let activeTerminalTarget = frontmostContext.activeTerminalTarget,
              let notificationTarget else {
            return false
        }
        return activeTerminalTarget == notificationTarget
    }

    @MainActor
    static func deliverIfNeeded(
        event: WorkstreamEvent,
        requestId: String,
        notificationTarget: ActiveTerminalTarget?,
        frontmostContext: FrontmostContext = currentFrontmostContext(),
        deliverRequest: (UNNotificationRequest) -> Void = deliver
    ) {
        guard !shouldSuppress(
            notificationTarget: notificationTarget,
            frontmostContext: frontmostContext
        ) else {
            return
        }
        guard let request = request(for: event, requestId: requestId) else { return }
        deliverRequest(request)
    }

    static func request(
        for event: WorkstreamEvent,
        requestId: String
    ) -> UNNotificationRequest? {
        let categoryId: String
        let title: String
        let body: String
        switch event.hookEventName {
        case .permissionRequest:
            categoryId = "CMUXFeedPermission"
            title = String(
                localized: "feed.notification.permission.title",
                defaultValue: "\(event.source.capitalized) permission"
            )
            body = event.toolName.map {
                String(
                    localized: "feed.notification.permission.body",
                    defaultValue: "\($0) needs approval"
                )
            } ?? String(
                localized: "feed.notification.decisionNeeded",
                defaultValue: "Decision needed"
            )
        case .exitPlanMode:
            categoryId = "CMUXFeedExitPlan"
            title = String(
                localized: "feed.notification.exitPlan.title",
                defaultValue: "\(event.source.capitalized) plan ready"
            )
            body = String(
                localized: "feed.notification.exitPlan.body",
                defaultValue: "Review and approve the plan"
            )
        case .askUserQuestion:
            categoryId = "CMUXFeedQuestion"
            title = String(
                localized: "feed.notification.question.title",
                defaultValue: "\(event.source.capitalized) question"
            )
            body = String(
                localized: "feed.notification.question.body",
                defaultValue: "Agent is asking a question"
            )
        default:
            return nil
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryId
        content.userInfo = [
            "requestId": requestId,
            "workstreamId": event.sessionId,
        ]

        return UNNotificationRequest(
            identifier: "feed.\(requestId)",
            content: content,
            trigger: nil
        )
    }

    @MainActor
    static func currentFrontmostContext() -> FrontmostContext {
        FrontmostContext(
            isAppFrontmost: AppFocusState.isAppFocused(),
            activeTerminalTarget: currentFocusedTerminalTarget()
        )
    }

    static func deliver(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                center.add(request) { _ in /* best effort */ }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) { _ in } }
                }
            default:
                break
            }
        }
    }

    static func resolvedTarget(
        for event: WorkstreamEvent,
        lookupTarget: (String, String) -> FeedJumpResolver.Target? = FeedJumpResolver.lookup
    ) -> ActiveTerminalTarget? {
        guard let parsed = FeedJumpResolver.parse(event.sessionId),
              let target = lookupTarget(parsed.agent, parsed.sessionId),
              let workspaceId = UUID(uuidString: target.workspaceId),
              let surfaceId = UUID(uuidString: target.surfaceId) else {
            return nil
        }
        return ActiveTerminalTarget(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    @MainActor
    private static func currentFocusedTerminalTarget() -> ActiveTerminalTarget? {
        let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let surfaceId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        return ActiveTerminalTarget(workspaceId: workspaceId, surfaceId: surfaceId)
    }
}
