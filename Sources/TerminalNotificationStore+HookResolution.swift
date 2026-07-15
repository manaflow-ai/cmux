import Foundation

extension TerminalNotificationStore {
    /// Resolves project-local hook configuration off the main actor for the
    /// bounded Ghostty OSC ingress, then re-enters the ordinary delivery path
    /// with an explicit hook snapshot. Other callers keep synchronous no-hook
    /// semantics through `addNotification`.
    func addDesktopNotificationResolvingHooks(
        tabId: UUID,
        surfaceId: UUID?,
        hookDirectory: String?,
        globalConfigPath: String,
        title: String,
        body: String
    ) async {
        let appDelegate = AppDelegate.shared
        let hooks = await notificationHookCache.hooks(
            startingFrom: hookDirectory,
            globalConfigPath: globalConfigPath
        )
        guard !Task.isCancelled else { return }
        guard let target = appDelegate?.agentNotificationDeliveryTarget(
            claimedTabId: tabId,
            surfaceId: surfaceId
        ) else { return }
        addNotification(
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            title: title,
            subtitle: "",
            body: body,
            resolvedHooks: hooks
        )
    }
}
