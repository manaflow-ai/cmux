import Foundation

extension TerminalNotificationStore {
    /// Resolves callback-time project hooks off the main actor, then resolves
    /// the live destination once for routing, suppression, and default-title
    /// selection. Other callers keep synchronous no-hook semantics through
    /// `addNotification`.
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
        guard let appDelegate,
              let target = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: tabId,
                surfaceId: surfaceId
              ),
              let owningManager = appDelegate.tabManagerFor(tabId: target.tabId) ?? appDelegate.tabManager else {
            return
        }
        let workspace = owningManager.workspacesById[target.tabId]
        guard workspace?.suppressesRawTerminalNotification(panelId: target.surfaceId) != true else { return }
        let resolvedTitle = title.isEmpty ? owningManager.titleForTab(target.tabId) ?? String(
            localized: "notification.desktop.defaultTerminalTitle",
            defaultValue: "Terminal"
        ) : title
        addNotification(
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            title: resolvedTitle,
            subtitle: "",
            body: body,
            resolvedHooks: hooks
        )
    }
}
