import Foundation

extension TerminalNotificationStore {
    /// Registers dismissible policy work before resolving callback-time hooks,
    /// then resolves the live destination once for routing, suppression, and
    /// default-title selection. Other callers keep synchronous no-hook
    /// semantics through `addNotification`.
    func addDesktopNotificationResolvingHooks(
        tabId: UUID,
        surfaceId: UUID?,
        hookDirectory: String?,
        title: String,
        body: String
    ) async {
        guard let appDelegate = AppDelegate.shared,
              let initialTarget = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: tabId,
                surfaceId: surfaceId
              ) else {
            return
        }
        let globalConfigPath = appDelegate.contextContainingTabId(initialTarget.tabId)?
            .cmuxConfigStore?.globalConfigPath
            ?? CmuxConfigStore.defaultGlobalConfigPath()
        let policyRequestId = beginDesktopNotificationHookResolution(
            tabId: initialTarget.tabId,
            surfaceId: initialTarget.surfaceId,
            title: title,
            body: body
        )
        var ownsPolicyRequest = true
        defer {
            if ownsPolicyRequest {
                abortDesktopNotificationHookResolution(policyRequestId)
            }
        }
        let hooks = await notificationHookCache.hooks(
            startingFrom: hookDirectory,
            globalConfigPath: globalConfigPath
        )
        guard !Task.isCancelled else { return }
        guard let target = appDelegate.agentNotificationDeliveryTarget(
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
        ownsPolicyRequest = false
        addNotification(
            tabId: target.tabId,
            surfaceId: target.surfaceId,
            title: resolvedTitle,
            subtitle: "",
            body: body,
            resolvedHooks: hooks,
            preRegisteredPolicyRequestId: policyRequestId
        )
    }
}
