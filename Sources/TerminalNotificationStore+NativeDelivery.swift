import Foundation
import UserNotifications

extension TerminalNotificationStore {
    func resolvedNotificationTitle(for notification: TerminalNotification) -> String {
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

        let nativeDeliveryHooks = nativeNotificationDeliveryHooks
        let notificationTitle = resolvedNotificationTitle(for: notification)
        let notificationSubtitle = notification.subtitle
        let notificationBody = notification.body
        let notificationId = notification.id
        let notificationTabId = notification.tabId
        let notificationSurfaceId = notification.surfaceId
        let retargetsToLiveSurfaceOwner = notification.retargetsToLiveSurfaceOwner
        let clickActionUserInfo = notification.clickAction?.userInfo ?? [:]
        let categoryIdentifier = Self.categoryIdentifier

        let handleAuthorization: NativeNotificationDeliveryHooks.AuthorizationCompletion = {
            authorized,
            effectiveAuthorizationState in
            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.subtitle = notificationSubtitle
            content.body = notificationBody
            guard authorized else {
                NativeNotificationDeliveryHooks.playNativeUnavailableFeedback(
                    effects: Self.fallbackEffects(effects, authorizationState: effectiveAuthorizationState)
                )
                return
            }
            content.sound = effects.sound ? NotificationSoundSettings.sound() : nil
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = [
                "tabId": notificationTabId.uuidString,
                "notificationId": notificationId.uuidString,
                Self.retargetsToLiveSurfaceOwnerUserInfoKey: retargetsToLiveSurfaceOwner,
            ]
            if let surfaceId = notificationSurfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }
            for (key, value) in clickActionUserInfo {
                content.userInfo[key] = value
            }

            let request = UNNotificationRequest(
                identifier: notificationId.uuidString,
                content: content,
                trigger: nil
            )
            let commandTitle = content.title
            let commandSubtitle = content.subtitle
            let commandBody = content.body

            nativeDeliveryHooks.schedule(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification error=\(error.localizedDescription, privacy: .private)"
                    )
                    NativeNotificationDeliveryHooks.playNativeUnavailableFeedback(effects: effects)
                } else if effects.command {
                    nativeDeliveryHooks.runCommand(
                        title: commandTitle,
                        subtitle: commandSubtitle,
                        body: commandBody
                    )
                }
            }
        }
        if !nativeDeliveryHooks.authorizeForTesting(handleAuthorization) {
            ensureAuthorization(origin: .notificationDelivery, handleAuthorization)
        }
    }

    func playSuppressedNotificationFeedback(
        for notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        nativeNotificationDeliveryHooks.runLocalFeedback(
            title: resolvedNotificationTitle(for: notification),
            subtitle: notification.subtitle,
            body: notification.body,
            effects: effects
        )
    }

    func playLocalNotificationFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        nativeNotificationDeliveryHooks.runLocalFeedback(
            title: title,
            subtitle: subtitle,
            body: body,
            effects: effects
        )
    }
}
