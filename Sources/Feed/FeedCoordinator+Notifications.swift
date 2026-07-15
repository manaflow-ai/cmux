import AppKit
import CMUXAgentLaunch
import Foundation
@preconcurrency import UserNotifications

// MARK: - Native notification banner

extension FeedCoordinator {
    /// Posts a UNUserNotificationCenter banner with inline action buttons
    /// for the given Feed event after optional notification policy hooks run.
    /// Notification eligibility is derived only from the waiter table so
    /// resolved/timed-out requests cannot enqueue stale banners while the main
    /// queue, policy hooks, or notification center catches up.
    func postNotificationIfStillAwaiting(event: WorkstreamEvent, requestId: String) {
        Task { @MainActor [weak self] in
            guard let self, self.isAwaitingDecision(requestId: requestId) else {
                return
            }

            #if DEBUG
            let isAppActive = FeedCoordinatorTestHooks.isAppActiveOverride?() ?? NSApp.isActive
            #else
            let isAppActive = NSApp.isActive
            #endif

            // Don't pester users while the app is already up front.
            if isAppActive {
                return
            }

            #if DEBUG
            if let observer = FeedCoordinatorTestHooks.notificationPostObserver {
                observer(event, requestId)
                return
            }
            #endif

            let categoryId: String
            let title: String
            let body: String
            switch event.hookEventName {
            case .permissionRequest:
                categoryId = Self.permissionNotificationCategoryId(for: event)
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
                return
            }

            let policyContext = FeedNotificationPolicyContext.make(
                event: event,
                title: title,
                body: body
            )
            let deliverDefault = { [weak self] in
                self?.deliverFeedNotificationIfStillAwaiting(
                    requestId: requestId,
                    event: event,
                    categoryId: categoryId,
                    title: title,
                    subtitle: "",
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
            guard self.isAwaitingDecision(requestId: requestId) else { return }
            guard !authorizedHooks.isEmpty else {
                deliverDefault()
                return
            }

            let result = await TerminalNotificationPolicyEngine.evaluate(
                envelope: policyContext.envelope,
                hooks: authorizedHooks
            )
            guard self.isAwaitingDecision(requestId: requestId) else { return }
            switch result {
            case .success(let envelope):
                let payload = envelope.notification
                self.deliverFeedNotificationIfStillAwaiting(
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
    }

    private static func permissionNotificationCategoryId(for event: WorkstreamEvent) -> String {
        let source = WorkstreamSource(wireName: event.source) ?? .claude
        let supportsOnce = FeedPermissionActionPolicy.supportsOncePermissionMode(
            source: source,
            toolInputJSON: event.toolInputJSON
        )
        let supportsAlways = FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
            source: source,
            toolInputJSON: event.toolInputJSON
        )
        let supportsAll = FeedPermissionActionPolicy.supportsAllPermissionMode(
            source: source,
            toolInputJSON: event.toolInputJSON
        )
        var suffix = ""
        if supportsOnce { suffix += "Once" }
        if supportsAlways { suffix += "Always" }
        if supportsAll { suffix += "All" }
        return suffix.isEmpty ? "CMUXFeedPermissionDeny" : "CMUXFeedPermission\(suffix)"
    }

    @MainActor
    func deliverFeedNotificationIfStillAwaiting(
        requestId: String,
        event: WorkstreamEvent,
        categoryId: String,
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard isAwaitingDecision(requestId: requestId),
              effects.desktop || effects.sound || effects.command
        else { return }

        if !effects.desktop {
            runFallbackEffectsIfStillAwaiting(
                requestId: requestId,
                title: title,
                subtitle: subtitle,
                body: body,
                effects: effects,
                runCommand: true
            )
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
            Task { @MainActor [weak self] in
                guard let self, self.isAwaitingDecision(requestId: requestId) else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.addNotificationIfStillAwaiting(
                        center: center,
                        request: request,
                        requestId: requestId,
                        effects: effects
                    )
                case .notDetermined:
                    var granted = false
                    var requestFailed = false
                    do {
                        granted = try await center.requestAuthorization(options: [.alert, .sound])
                    } catch {
                        requestFailed = true
                    }
                    guard self.isAwaitingDecision(requestId: requestId) else { return }
                    if granted {
                        self.addNotificationIfStillAwaiting(
                            center: center,
                            request: request,
                            requestId: requestId,
                            effects: effects
                        )
                    } else {
                        // A non-grant without an error is the user declining
                        // the prompt just now: honor the fresh denial on this
                        // very notification. A request error is not a user
                        // decision, so the fallback stays audible (fail-open).
                        self.runFallbackEffectsIfStillAwaiting(
                            requestId: requestId,
                            title: title,
                            subtitle: subtitle,
                            body: body,
                            effects: TerminalNotificationStore.fallbackEffects(
                                effects,
                                authorizationState: requestFailed ? .unknown : .denied
                            ),
                            runCommand: false
                        )
                    }
                default:
                    self.runFallbackEffectsIfStillAwaiting(
                        requestId: requestId,
                        title: title,
                        subtitle: subtitle,
                        body: body,
                        effects: TerminalNotificationStore.fallbackEffects(
                            effects,
                            authorizationState: TerminalNotificationStore.authorizationState(
                                from: settings.authorizationStatus
                            )
                        ),
                        runCommand: false
                    )
                }
            }
        }
    }

    @MainActor
    func addNotificationIfStillAwaiting(
        center: UNUserNotificationCenter,
        request: UNNotificationRequest,
        requestId: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard isAwaitingDecision(requestId: requestId) else { return }
        let title = request.content.title
        let subtitle = request.content.subtitle
        let body = request.content.body
        center.add(request) { error in
            let didFail = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isAwaitingDecision(requestId: requestId) {
                    self.cancelNotification(requestId: requestId)
                    return
                }
                if didFail {
                    self.runFallbackEffectsIfStillAwaiting(
                        requestId: requestId,
                        title: title,
                        subtitle: subtitle,
                        body: body,
                        effects: effects,
                        runCommand: false
                    )
                    return
                }
                if effects.command {
                    NotificationSoundSettings.runCustomCommand(
                        title: title,
                        subtitle: subtitle,
                        body: body
                    )
                }
            }
        }
    }

    @MainActor
    func runFallbackEffectsIfStillAwaiting(
        requestId: String,
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects,
        runCommand: Bool
    ) {
        guard isAwaitingDecision(requestId: requestId) else { return }
        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: title,
            subtitle: subtitle,
            body: body,
            effects: effects, runCommand: runCommand
        )
    }

    func cancelNotification(requestId: String) {
        let identifier = "feed.\(requestId)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequestsOffMain(withIdentifiers: [identifier])
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [identifier])
    }
}
