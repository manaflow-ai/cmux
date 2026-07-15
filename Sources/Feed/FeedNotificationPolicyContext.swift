import CMUXAgentLaunch
import CmuxSettings
import Foundation

struct FeedNotificationPolicyContext {
    let envelope: TerminalNotificationPolicyEnvelope
    let hooks: [CmuxResolvedNotificationHook]
    let globalConfigPath: String?
}

extension FeedNotificationPolicyContext {
    @MainActor
    static func make(
        event: WorkstreamEvent,
        title: String,
        body: String
    ) -> FeedNotificationPolicyContext {
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
        effects.desktop = true
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.sound = false
        effects.command = false
        effects.paneFlash = false

        return FeedNotificationPolicyContext(
            envelope: TerminalNotificationPolicyEnvelope(
                notification: TerminalNotificationPolicyPayload(
                    workspaceId: event.workspaceId ?? event.sessionId,
                    surfaceId: nil,
                    title: title,
                    subtitle: "",
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
            hooks: context?.cmuxConfigStore?.notificationHooks(
                startingFrom: workspace?.isRemoteWorkspace == true
                    ? nil
                    : (normalizedCWD(event.cwd) ?? workspace?.surfaceTabBarDirectory)
            ) ?? [],
            globalConfigPath: context?.cmuxConfigStore?.globalConfigPath
        )
    }

    private static func normalizedCWD(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
