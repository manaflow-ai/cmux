import CmuxNextCompat
import CmuxNextSettings

// Launch calls for Home, the chats feed, the New Tab page's feeds and its spare (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// Chat settings, the chats feed and its importers, the New Tab feeds, the GitHub feed and the New Tab spare.
    func registerHome(services: AppServices, settings: SettingsController) {
        // An attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) keeps its owner's chat settings.
        let acpmux = QuitAgents.environment(services)
        ChatSettingsPush.start(settings: settings, socketPath: acpmux?.isAttached == true ? nil : acpmux?.socketPath)
        services.chatsFeed?.keepCurrent()
        services.projectsImport.start(feed: services.chatsFeed)
        if let feed = services.chatsFeed { AgentPageChats.wire(services.agentTabs, to: feed, opener: services.chatsOpener) }
        AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        NewTabClosed.wire(services.agentTabs, services: services)
        NewTabPlacesFeed.wire(services.agentTabs, services: services)
        NewTabWeather.wire(services.agentTabs, services: services)
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        Task { [weak services, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await github in ObservationStream({ settings.snapshot.feedGitHub }) {
                services?.feed.configureGitHub(enabled: github.enabled, pollIntervalSeconds: github.pollIntervalSeconds)
            }
        }
        services.newTabSpares.prewarm() // the first agent page loads while the windows build (cx-z9kz0)
    }

    /// Home's feeds and cache.
    func registerHomePage(services: AppServices) {
        services.home.start()
    }
}
