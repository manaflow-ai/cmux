import CmuxNextAgentPane
import CmuxNextFeatures
import CmuxNextLaunch
import CmuxNextWakeups

// Launch work no first frame needs, one StartupScheduler post per service (`LaunchServicePosts`, p08-startup-017).
extension AppServices {
    /// The free-tier attest, SSH, server reach, the updater (Sparkle) and the empty-workspace repair (built here
    /// when no window's content built it first).
    func postNonPaintServices(on startup: StartupScheduler) {
        let attest = FreeTierAttestStarter(build: environment.build, bundle: .main, apiBaseURL: FeedService.apiBaseURL(auth: cloudAuth), settings: settings, signedIn: { [weak self] in self.map { $0.cloudAuth.isSignedIn || $0.cloudAuth.isRestoring } ?? true })
        LaunchServicePosts.nonPaint(freeTierAttest: { attest.start() }, ssh: { [weak self] in self?.ssh.start() }, serverReach: { [weak self] in self?.serverReach.start() },
                                    updater: { [weak self] in self?.updater.start(); DebugTimings.markLaunch("launch.non_paint_services") },
                                    emptyWorkspaceRepair: { [weak self] in _ = self?.emptyWorkspaces }).post(on: startup)
    }

    /// Warm-ups for later tabs (WebKit for agent pages, Chromium, the New Tab spare, page hosts), the agent tab
    /// import and the right sidebar's icons (on the cpu lane; a panel built first posted them already).
    func postLaterTabWarmups(on startup: StartupScheduler) {
        LaunchServicePosts.laterTabs(chromiumWarmup: { [weak self] in if let self, !crashRecovery.recovery.skipsBrowserPages { startChromiumWarmup() } },
                                     spareHooks: { [weak self] in self?.newTabSpares.start(holdingWarm: true) }, spareWarming: { [weak self] in self?.newTabSpares.startWarming() },
                                     pageHostPool: { [weak self] in
                                         guard let self else { return }
                                         pageHostPool.start(isMainWindow: { [weak self] window in self?.windows.controllers.contains { $0.window === window } == true },
                                                            fallback: { [weak self] window in self?.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible } })
                                         pageHostPool.noteLikely()
                                     },
                                     agentTabImport: { [weak self] in if let self { AgentTabImport.start(self); DebugTimings.markLaunch("launch.post_window_warmups") } },
                                     rightSidebarIcons: { [weak self] in self?.rightSidebarSections.buildIcons(.afterStartup) }).post(on: startup)
        let warmup = AgentPageWarmupSlot(startup: startup) { [weak self] in DebugTimings.markLaunch(self.map { $0.agentPageWarmup.start(webUI: $0.webUI) } == true ? "launch.agent_page_warmup" : "launch.agent_page_warmup_not_needed") }
        windows.whenRestored { [weak self] in warmup.restored(showsWebKitAgentChat: self?.showsWebKitAgentChat == true) }
    }

    /// Runs one launch start by its class (p06-scheduler-049, `LaunchStart`): a first-frame start now; a start the first
    /// frame does not need as an afterStartup post on ``launchStartup`` with feature `launchStartDeferral`, else now.
    /// With no launch scheduler (a test's services) it runs now and reads no feature, so a test may still set ``features``.
    func runLaunchStart(_ start: LaunchStart, _ work: @escaping @MainActor @Sendable () -> Void) {
        guard let launchStartup, start.startClass != .firstFrame else { return work() }
        start.run(on: launchStartup, deferring: features.isEnabled(.launchStartDeferral), work)
    }

    /// Restart cmux-tui… is bound now (the CLI and palette may run it any time); the handshake follow, its toasts and
    /// its tailnet address read are ``LaunchStart/serverUpdates``.
    func startServerUpdates() {
        serverUpdates.bind(registry: registry)
        runLaunchStart(.serverUpdates) { [weak self] in self?.serverUpdates.follow() }
    }

    /// The installed-update card in the Feed (``LaunchStart/updateFeed``; following it builds the Feed).
    func followUpdateFeed() {
        runLaunchStart(.updateFeed) { [weak self] in if let self { updateFeedObservation = UpdateFeedPosting.follow(self) } }
    }

    /// The front window's focused pane shows an agent chat (`agentSession` is a conversation's only) that opens in WebKit.
    private var showsWebKitAgentChat: Bool { windows.active?.focusedPane?.selectedTab?.agentSession != nil && AgentPaneView.newPagesShowInWebKit(
        chromiumChat: AgentPaneTunables.chromium.value, hosting: webUI.chromium) }
}
