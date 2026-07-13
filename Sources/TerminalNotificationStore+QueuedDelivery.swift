import Foundation

extension TerminalNotificationStore {
    func deliverQueuedNotification(_ notification: QueuedTerminalNotification) {
        guard shouldDeliverQueuedNotification(notification) else {
#if DEBUG
            cmuxDebugLog(
                "notification.queue.deliver.skip workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") reason=targetMissing titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
            )
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "notification.queue.deliver workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
        )
#endif
        addNotification(
            id: notification.id,
            acceptedAt: notification.acceptedAt,
            tabId: notification.key.tabId,
            surfaceId: notification.key.surfaceId,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body
        )
    }

    private func shouldDeliverQueuedNotification(_ notification: QueuedTerminalNotification) -> Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        guard let surfaceId = notification.key.surfaceId else {
            let tabManager = appDelegate.tabManagerFor(tabId: notification.key.tabId) ?? appDelegate.tabManager
            return tabManager?.tabs.contains(where: { $0.id == notification.key.tabId }) == true
        }

        guard let target = appDelegate.workspaceContainingPanel(
            panelId: surfaceId,
            preferredWorkspaceId: notification.key.tabId
        ) else {
            return false
        }
        return target.workspace.id == notification.key.tabId
    }

    static func cachedDeliveryAuthorizationDecision(
        for state: NotificationAuthorizationState,
        isAppActive: Bool
    ) -> Bool? {
        switch state {
        case .authorized, .provisional, .ephemeral:
            return nil
        case .denied:
            return false
        case .notDetermined:
            return isAppActive ? nil : false
        case .unknown:
            return nil
        }
    }

    /// Effects for the out-of-band fallback path, where cmux plays feedback
    /// itself because the OS will not deliver the banner.
    ///
    /// A user who explicitly turned cmux notifications off (`.denied`) asked
    /// for silence, so the direct `NSSound` fallback must not punch through
    /// the denial (https://github.com/manaflow-ai/cmux/issues/5650). Every
    /// other state keeps the audible fallback: fresh installs
    /// (`.notDetermined`) have expressed no preference, and granted states
    /// only reach the fallback when delivery itself failed.
    nonisolated static func fallbackEffects(
        _ effects: TerminalNotificationPolicyEffects,
        authorizationState: NotificationAuthorizationState
    ) -> TerminalNotificationPolicyEffects {
        guard authorizationState == .denied else { return effects }
        var silenced = effects
        silenced.sound = false
        return silenced
    }
}
