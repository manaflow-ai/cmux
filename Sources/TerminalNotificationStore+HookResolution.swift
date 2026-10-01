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
        body: String,
        subtitle: String = "",
        origin: TerminalNotificationOrigin = .local
    ) async {
        guard let appDelegate = AppDelegate.shared,
              let initialTarget = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: tabId,
                surfaceId: surfaceId
              ) else {
            return
        }
        guard !isWorkspaceNotificationsMuted(forTabId: initialTarget.tabId) else {
            return
        }
        let initialManager = initialTarget.surfaceId.flatMap {
            appDelegate.notificationSurfaceOwner(
                surfaceID: $0,
                preferredTabID: initialTarget.tabId
            )?.tabManager
        }
            ?? appDelegate.tabManagerFor(tabId: initialTarget.tabId)
            ?? appDelegate.tabManager
        let globalConfigPath = initialManager.flatMap {
            appDelegate.mainWindowContext(for: $0)?.cmuxConfigStore?.globalConfigPath
        }
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
        // A remote emitter (ssh relay, cloud machine) never resolves project hooks from a
        // local directory: only the global config the user wrote on this Mac applies.
        let hooks = await notificationHookCache.hooks(
            startingFrom: origin.isRemote ? nil : hookDirectory,
            globalConfigPath: globalConfigPath
        )
        guard !Task.isCancelled else { return }
        guard let target = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: tabId,
                surfaceId: surfaceId
              ) else {
            return
        }
        guard !isWorkspaceNotificationsMuted(forTabId: target.tabId) else {
            return
        }
        let owningManager = target.surfaceId.flatMap {
            appDelegate.notificationSurfaceOwner(
                surfaceID: $0,
                preferredTabID: target.tabId
            )?.tabManager
        }
            ?? appDelegate.tabManagerFor(tabId: target.tabId)
            ?? appDelegate.tabManager
        guard let owningManager else {
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
            subtitle: subtitle,
            body: body,
            resolvedHooks: hooks,
            preRegisteredPolicyRequestId: policyRequestId,
            origin: origin
        )
    }
}
