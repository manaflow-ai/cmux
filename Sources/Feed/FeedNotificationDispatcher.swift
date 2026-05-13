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
        frontmostContext: FrontmostContext? = nil,
        deliverRequest: (WorkstreamEvent, String, UNNotificationRequest) -> Void = deliver
    ) {
        let frontmostContext = frontmostContext ?? currentFrontmostContext()
        guard !shouldSuppress(
            notificationTarget: notificationTarget,
            frontmostContext: frontmostContext
        ) else {
            return
        }
        guard let request = request(for: event, requestId: requestId) else { return }
        deliverRequest(event, requestId, request)
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

    static func deliver(
        event: WorkstreamEvent,
        requestId: String,
        request: UNNotificationRequest
    ) {
        let categoryId = request.content.categoryIdentifier
        let title = request.content.title
        let subtitle = request.content.subtitle
        let body = request.content.body

        Task { @MainActor in
            await deliverWithPolicy(
                event: event,
                requestId: requestId,
                categoryId: categoryId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
    }

    @MainActor
    private static func deliverWithPolicy(
        event: WorkstreamEvent,
        requestId: String,
        categoryId: String,
        title: String,
        subtitle: String,
        body: String
    ) async {
        let policyContext = makePolicyContext(
            event: event,
            title: title,
            subtitle: subtitle,
            body: body
        )
        let deliverDefault = {
            deliverFeedNotification(
                requestId: requestId,
                event: event,
                categoryId: categoryId,
                title: title,
                subtitle: subtitle,
                body: body,
                effects: policyContext.envelope.effects
            )
        }

        guard !policyContext.hooks.isEmpty else {
            deliverDefault()
            return
        }

        let authorizedHooks = await NotificationPolicyHookAuthorizer.authorize(
            policyContext.hooks,
            globalConfigPath: policyContext.globalConfigPath
        )
        guard !authorizedHooks.isEmpty else {
            deliverDefault()
            return
        }

        let result = await TerminalNotificationPolicyEngine.evaluate(
            envelope: policyContext.envelope,
            hooks: authorizedHooks
        )
        switch result {
        case .success(let envelope):
            let payload = envelope.notification
            deliverFeedNotification(
                requestId: requestId,
                event: event,
                categoryId: categoryId,
                title: payload.title,
                subtitle: payload.subtitle,
                body: payload.body,
                effects: envelope.effects
            )
        case .failure(let failure):
            deliverDefault()
            TerminalNotificationStore.shared.reportNotificationHookFailure(failure)
        }
    }

    private struct PolicyContext {
        let envelope: TerminalNotificationPolicyEnvelope
        let hooks: [CmuxResolvedNotificationHook]
        let globalConfigPath: String?
    }

    @MainActor
    private static func makePolicyContext(
        event: WorkstreamEvent,
        title: String,
        subtitle: String,
        body: String
    ) -> PolicyContext {
        let appDelegate = AppDelegate.shared
        let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:))
        let context = workspaceID.flatMap { appDelegate?.contextContainingTabId($0) }
            ?? appDelegate?.mainWindowContexts.values.first(where: { $0.cmuxConfigStore != nil })
        let workspace = workspaceID.flatMap { id in
            context?.tabManager.tabs.first(where: { $0.id == id })
        }
        let cwd = normalizedCWD(event.cwd)
            ?? workspace?.surfaceTabBarDirectory
            ?? workspace?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        var effects = TerminalNotificationPolicyEffects()
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.sound = false
        effects.command = false
        effects.paneFlash = false

        return PolicyContext(
            envelope: TerminalNotificationPolicyEnvelope(
                notification: TerminalNotificationPolicyPayload(
                    workspaceId: event.workspaceId ?? event.sessionId,
                    surfaceId: nil,
                    title: title,
                    subtitle: subtitle,
                    body: body
                ),
                context: TerminalNotificationPolicyContext(
                    cwd: cwd,
                    configPath: nil,
                    hookId: nil,
                    appFocused: AppFocusState.isAppFocused(),
                    focusedPanel: false
                ),
                effects: effects
            ),
            hooks: context?.cmuxConfigStore?.notificationHooks(startingFrom: cwd) ?? [],
            globalConfigPath: context?.cmuxConfigStore?.globalConfigPath
        )
    }

    private static func normalizedCWD(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private static func deliverFeedNotification(
        requestId: String,
        event: WorkstreamEvent,
        categoryId: String,
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.desktop || effects.sound || effects.command else { return }

        func runFallbackEffects() {
            if effects.sound {
                NotificationSoundSettings.playSelectedSound()
            }
            if effects.command {
                NotificationSoundSettings.runCustomCommand(
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            }
        }

        if !effects.desktop {
            runFallbackEffects()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = effects.sound ? NotificationSoundSettings.sound() : nil
        content.categoryIdentifier = categoryId
        content.userInfo = [
            "requestId": requestId,
            "workstreamId": event.sessionId,
        ]

        let request = UNNotificationRequest(
            identifier: "feed.\(requestId)",
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                center.add(request) { _ in
                    if effects.command {
                        NotificationSoundSettings.runCustomCommand(
                            title: content.title,
                            subtitle: content.subtitle,
                            body: content.body
                        )
                    }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        center.add(request) { _ in
                            if effects.command {
                                NotificationSoundSettings.runCustomCommand(
                                    title: content.title,
                                    subtitle: content.subtitle,
                                    body: content.body
                                )
                            }
                        }
                    }
                    if !granted {
                        runFallbackEffects()
                    }
                }
            default:
                runFallbackEffects()
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
