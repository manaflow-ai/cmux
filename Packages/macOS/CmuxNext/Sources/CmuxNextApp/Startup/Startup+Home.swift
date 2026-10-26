import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextSettings

// Launch calls for the chat settings, the chats pager and Home's feeds (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// The chat settings push; returns the acpmux environment the chats pager uses too.
    func registerChatSettings(services: AppServices, settings: SettingsController) -> AcpmuxEnvironment? {
        // An attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) keeps its owner's chat settings.
        let acpmux = QuitAgents.environment(services)
        ChatSettingsPush.start(settings: settings, socketPath: acpmux?.isAttached == true ? nil : acpmux?.socketPath)
        return acpmux
    }

    /// The chats pager, Home's launch feeds and the GitHub feed.
    func registerHomeFeeds(services: AppServices, settings: SettingsController, acpmux: AcpmuxEnvironment?) {
        // A page's chat clicks and All chats pages work from its first frame; the feeds come after it (p08-startup-027).
        AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        services.home.postLaunchFeeds(startup: order.startup)
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        Task { [weak services, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await github in ObservationStream({ settings.snapshot.feedGitHub }) {
                services?.configureFeedGitHub(enabled: github.enabled, pollIntervalSeconds: github.pollIntervalSeconds)  // builds no feed
            }
        }
    }
}
