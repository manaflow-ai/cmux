import CmuxNextAgentPane
import CmuxNextLaunch
import CmuxNextWakeups

// Launch work no first frame needs, one StartupScheduler post per service (`LaunchServicePosts`, p08-startup-017).
extension AppServices {
    /// The free-tier attest, SSH, server reach and the updater (Sparkle).
    func postNonPaintServices(on startup: StartupScheduler) {
        let attest = FreeTierAttestStarter(build: environment.build, bundle: .main, apiBaseURL: FeedService.apiBaseURL(auth: cloudAuth), settings: settings, signedIn: { [weak self] in self.map { $0.cloudAuth.isSignedIn || $0.cloudAuth.isRestoring } ?? true })
        LaunchServicePosts.nonPaint(freeTierAttest: { attest.start() }, ssh: { [weak self] in self?.ssh.start() }, serverReach: { [weak self] in self?.serverReach.start() },
                                    updater: { [weak self] in self?.updater.start(); DebugTimings.markLaunch("launch.non_paint_services") }).post(on: startup)
    }

    /// Warm-ups for later tabs (WebKit for agent pages, Chromium, the New Tab spare, page hosts) and the agent tab import.
    func postLaterTabWarmups(on startup: StartupScheduler) {
        LaunchServicePosts.laterTabs(chromiumWarmup: { [weak self] in if let self, !crashRecovery.recovery.skipsBrowserPages { startChromiumWarmup() } },
                                     spareHooks: { [weak self] in self?.newTabSpares.start(holdingWarm: true) }, spareWarming: { [weak self] in self?.newTabSpares.startWarming() },
                                     pageHostPool: { [weak self] in
                                         guard let self else { return }
                                         pageHostPool.start(isMainWindow: { [weak self] window in self?.windows.controllers.contains { $0.window === window } == true },
                                                            fallback: { [weak self] window in self?.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible } })
                                         pageHostPool.noteLikely()
                                     },
                                     agentTabImport: { [weak self] in if let self { AgentTabImport.start(self); DebugTimings.markLaunch("launch.post_window_warmups") } }).post(on: startup)
        let warmup = AgentPageWarmupSlot(startup: startup) { [weak self] in DebugTimings.markLaunch(self.map { $0.agentPageWarmup.start(webUI: $0.webUI) } == true ? "launch.agent_page_warmup" : "launch.agent_page_warmup_not_needed") }
        windows.whenRestored { [weak self] in warmup.restored(showsWebKitAgentChat: self?.showsWebKitAgentChat == true) }
    }

    /// The front window's focused pane shows an agent chat (`agentSession` is a conversation's only) that opens in WebKit.
    private var showsWebKitAgentChat: Bool { windows.active?.focusedPane?.selectedTab?.agentSession != nil && AgentPaneView.newPagesShowInWebKit(
        chromiumChat: AgentPaneTunables.chromium.value, hosting: webUI.chromium) }
}
