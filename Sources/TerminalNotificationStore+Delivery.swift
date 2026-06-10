import AppKit
import Foundation
import os
import UserNotifications
import Bonsplit


// MARK: - Notification intake, policy & delivery pipeline
extension TerminalNotificationStore {
    func addNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
#if DEBUG
        cmuxDebugLog(
            "notification.store.add workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count) cooldown=\(cooldownKey == nil ? 0 : 1)"
        )
#endif
        let now = Date()
        let resolvedCooldownInterval: TimeInterval?
        if let cooldownInterval, cooldownInterval.isFinite, cooldownInterval > 0 {
            resolvedCooldownInterval = cooldownInterval
        } else {
            resolvedCooldownInterval = nil
        }
        if let cooldownKey,
           let resolvedCooldownInterval,
           let lastNotificationDate = lastNotificationDateByCooldownKey[cooldownKey],
           now.timeIntervalSince(lastNotificationDate) < resolvedCooldownInterval {
#if DEBUG
            cmuxDebugLog(
                "notification.store.add.skip workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId?.uuidString.prefix(8) ?? "nil") reason=cooldown"
            )
#endif
            return
        }
        let cooldownReservation = makeCooldownReservation(
            key: cooldownKey,
            interval: resolvedCooldownInterval
        )
        if let cooldownReservation {
            lastNotificationDateByCooldownKey[cooldownReservation.key] = now
        }

        let policyContext = makeNotificationPolicyContext(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
        guard !policyContext.hooks.isEmpty else {
            applyNotification(
                request: policyContext.request,
                effects: TerminalNotificationPolicyEffects(),
                now: now,
                cooldownReservation: cooldownReservation,
                clickAction: clickAction
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let authorizedHooks = await NotificationPolicyHookAuthorizer.authorize(
                policyContext.hooks,
                globalConfigPath: policyContext.globalConfigPath
            )
            guard !authorizedHooks.isEmpty else {
                self.applyNotification(
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    clickAction: clickAction
                )
                return
            }

            let result = await TerminalNotificationPolicyEngine.evaluate(
                request: policyContext.request,
                hooks: authorizedHooks
            )
            switch result {
            case .success(let envelope):
                self.applyNotification(
                    request: policyContext.request,
                    envelope: envelope,
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    clickAction: clickAction
                )
            case .failure(let failure):
                self.applyNotification(
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    clickAction: clickAction
                )
                self.reportNotificationHookFailure(failure)
            }
        }
    }

    private struct NotificationCooldownReservation: Sendable {
        let key: String
        let previousDate: Date?
    }

    private struct NotificationPolicyContext: Sendable {
        let request: TerminalNotificationPolicyRequest
        let hooks: [CmuxResolvedNotificationHook]
        let globalConfigPath: String?
    }

    private func makeCooldownReservation(
        key: String?,
        interval: TimeInterval?
    ) -> NotificationCooldownReservation? {
        guard let key, interval != nil else { return nil }
        return NotificationCooldownReservation(
            key: key,
            previousDate: lastNotificationDateByCooldownKey[key]
        )
    }

    private func commitCooldownReservation(
        _ reservation: NotificationCooldownReservation?,
        at date: Date
    ) {
        guard let reservation else { return }
        lastNotificationDateByCooldownKey[reservation.key] = date
    }

    private func restoreCooldownReservation(_ reservation: NotificationCooldownReservation?) {
        guard let reservation else { return }
        if let previousDate = reservation.previousDate {
            lastNotificationDateByCooldownKey[reservation.key] = previousDate
        } else {
            lastNotificationDateByCooldownKey.removeValue(forKey: reservation.key)
        }
    }

    private func makeNotificationPolicyContext(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) -> NotificationPolicyContext {
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager ?? appDelegate?.tabManagerFor(tabId: tabId) ?? appDelegate?.tabManager
        let cmuxConfigStore = context?.cmuxConfigStore
        let workspace = tabManager?.tabs.first(where: { $0.id == tabId })
        let focusedSurfaceId = tabManager?.focusedSurfaceId(for: tabId)
        let isActiveTab = tabManager?.selectedTabId == tabId
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let cwd = workspace?.surfaceTabBarDirectory
            ?? workspace?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let panelId: UUID? = surfaceId.flatMap { surfaceId in
            if workspace?.panels[surfaceId] != nil {
                return surfaceId
            }
            return workspace?.panelIdFromSurfaceId(TabID(uuid: surfaceId))
        }

        return NotificationPolicyContext(
            request: TerminalNotificationPolicyRequest(
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId,
                title: title,
                subtitle: subtitle,
                body: body,
                cwd: cwd,
                isAppFocused: isAppFocused,
                isFocusedPanel: isFocusedPanel
            ),
            hooks: cmuxConfigStore?.notificationHooks(startingFrom: cwd) ?? [],
            globalConfigPath: cmuxConfigStore?.globalConfigPath
        )
    }

    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        envelope: TerminalNotificationPolicyEnvelope,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        clickAction: TerminalNotificationClickAction?
    ) {
        let payload = envelope.notification
        applyNotification(
            request: TerminalNotificationPolicyRequest(
                tabId: request.tabId,
                surfaceId: request.surfaceId,
                panelId: request.panelId,
                title: payload.title,
                subtitle: payload.subtitle,
                body: payload.body,
                cwd: request.cwd,
                isAppFocused: request.isAppFocused,
                isFocusedPanel: request.isFocusedPanel
            ),
            effects: envelope.effects,
            now: now,
            cooldownReservation: cooldownReservation,
            clickAction: clickAction
        )
    }

    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        effects: TerminalNotificationPolicyEffects,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        clickAction: TerminalNotificationClickAction?
    ) {
        let shouldSuppressExternalDelivery = shouldSuppressExternalDelivery(
            tabId: request.tabId,
            surfaceId: request.surfaceId
        )
        let notification = TerminalNotification(
            id: UUID(),
            tabId: request.tabId,
            surfaceId: request.surfaceId,
            panelId: request.panelId,
            title: request.title,
            subtitle: request.subtitle,
            body: request.body,
            createdAt: now,
            isRead: !effects.markUnread,
            paneFlash: effects.paneFlash,
            clickAction: clickAction
        )

        if effects.record {
            recordNotification(
                notification,
                shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
                effects: effects,
                now: now,
                cooldownReservation: cooldownReservation
            )
            return
        }

#if DEBUG
        cmuxDebugLog(
            "notification.store.effectsOnly workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") desktop=\(effects.desktop ? 1 : 0) sound=\(effects.sound ? 1 : 0) command=\(effects.command ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0)"
        )
#endif
        if effects.reorderWorkspace, WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        }
        if hasAnyNotificationEffect(effects) {
            commitCooldownReservation(cooldownReservation, at: now)
        } else {
            restoreCooldownReservation(cooldownReservation)
        }
        deliverNotificationSideEffects(
            notification,
            shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
            effects: effects
        )
    }

    private func recordNotification(
        _ notification: TerminalNotification,
        shouldSuppressExternalDelivery: Bool,
        effects: TerminalNotificationPolicyEffects,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?
    ) {
        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == notification.tabId, existing.surfaceId == notification.surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        if let existingIndicatorSurfaceId = focusedReadIndicatorByTabId[notification.tabId],
           existingIndicatorSurfaceId != notification.surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: notification.tabId)
        }

        if shouldSuppressExternalDelivery, effects.markUnread {
            setFocusedReadIndicator(forTabId: notification.tabId, surfaceId: notification.surfaceId)
        }

        if effects.reorderWorkspace, WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        }

        updated.insert(notification, at: 0)
        setWorkspaceManualUnread(false, forTabId: notification.tabId)
        notifications = updated
        commitCooldownReservation(cooldownReservation, at: now)
#if DEBUG
        cmuxDebugLog(
            "notification.store.record workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") removed=\(idsToClear.count) unread=\(!notification.isRead ? 1 : 0) paneFlash=\(notification.paneFlash ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0) total=\(notifications.count)"
        )
#endif
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        deliverNotificationSideEffects(
            notification,
            shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
            effects: effects
        )
    }

    private func shouldSuppressExternalDelivery(tabId: UUID, surfaceId: UUID?) -> Bool {
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager ?? appDelegate?.tabManagerFor(tabId: tabId) ?? appDelegate?.tabManager
        let focusedSurfaceId = tabManager?.focusedSurfaceId(for: tabId)
        let isActiveTab = tabManager?.selectedTabId == tabId
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        return AppFocusState.isAppFocused() && isActiveTab && isFocusedSurface
    }

    private func deliverNotificationSideEffects(
        _ notification: TerminalNotification,
        shouldSuppressExternalDelivery: Bool,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.desktop || effects.sound || effects.command else {
#if DEBUG
            cmuxDebugLog(
                "notification.store.sideEffects.skip workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") reason=noEffects"
            )
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "notification.store.sideEffects workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") desktop=\(effects.desktop ? 1 : 0) sound=\(effects.sound ? 1 : 0) command=\(effects.command ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0)"
        )
#endif
        if shouldSuppressExternalDelivery {
            suppressedNotificationFeedbackHandler(self, notification, effects)
        } else {
            notificationDeliveryHandler(self, notification, effects)
            // Mirror to the user's iPhone (opt-in, off by default). Only on the
            // desktop-delivery path so it matches what the Mac actually shows;
            // suppressed/focused notifications are not forwarded.
            if effects.desktop {
                PhonePushClient.shared.forward(notification)
            }
        }
    }

    private func hasAnyNotificationEffect(_ effects: TerminalNotificationPolicyEffects) -> Bool {
        effects.record || effects.desktop || effects.sound || effects.command || effects.reorderWorkspace || effects.markUnread
    }

    func reportNotificationHookFailure(_ failure: TerminalNotificationPolicyFailure) {
        let key = NotificationHookFailureThrottleKey(
            hookId: failure.hookId,
            sourcePath: failure.sourcePath
        )
        let now = Date()
        if let lastDate = lastNotificationHookFailureDateByKey[key],
           now.timeIntervalSince(lastDate) < Self.notificationHookFailureThrottle {
            return
        }
        lastNotificationHookFailureDateByKey[key] = now
        terminalNotificationLogger.error(
            "Notification hook failed hookId=\(failure.hookId, privacy: .public) sourcePath=\(failure.sourcePath ?? "<unknown>", privacy: .private) message=\(failure.message, privacy: .private)"
        )

        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self, authorized else { return }
            let title = String(
                localized: "notificationHook.failure.title",
                defaultValue: "Notification Hook Failed"
            )
            let format = String(
                localized: "notificationHook.failure.body",
                defaultValue: "cmux used default notification behavior because '%@' failed."
            )
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(format: format, failure.hookId)
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            let request = UNNotificationRequest(
                identifier: "cmux.notification-hook.failure.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            self.center.add(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification hook failure alert error=\(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }
    }

    private func resolvedNotificationTitle(for notification: TerminalNotification) -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        return notification.title.isEmpty ? appName : notification.title
    }

    func scheduleUserNotification(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.desktop else {
            playLocalNotificationFeedback(
                title: resolvedNotificationTitle(for: notification),
                subtitle: notification.subtitle,
                body: notification.body,
                effects: effects
            )
            return
        }

        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self else { return }
            let content = UNMutableNotificationContent()
            content.title = self.resolvedNotificationTitle(for: notification)
            content.subtitle = notification.subtitle
            content.body = notification.body
            guard authorized else {
                self.playLocalNotificationFeedback(
                    title: content.title,
                    subtitle: content.subtitle,
                    body: content.body,
                    effects: effects
                )
                return
            }
            content.sound = effects.sound ? NotificationSoundSettings.sound() : nil
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }
            if let clickAction = notification.clickAction {
                for (key, value) in clickAction.userInfo {
                    content.userInfo[key] = value
                }
            }

            let request = UNNotificationRequest(
                identifier: notification.id.uuidString,
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification error=\(error.localizedDescription, privacy: .private)"
                    )
                    Task { @MainActor [weak self] in
                        self?.playLocalNotificationFeedback(
                            title: content.title,
                            subtitle: content.subtitle,
                            body: content.body,
                            effects: effects
                        )
                    }
                } else if effects.command {
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    func playSuppressedNotificationFeedback(
        for notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        playLocalNotificationFeedback(
            title: resolvedNotificationTitle(for: notification),
            subtitle: notification.subtitle,
            body: notification.body,
            effects: effects
        )
    }

    private func playLocalNotificationFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects
    ) {
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

}
