import CmuxNextAgentPane
import CmuxNextFeatures
import CmuxNextKeepAwake
import CmuxNextLaunch
import CmuxNextSettings
import CmuxNextWakeups

// Launch work no first frame needs, one StartupScheduler post per service (`LaunchServicePosts`, p08-startup-017).
extension AppServices {
    /// The starts `init` does not make (`serviceStartPosts()`), then the free-tier attest, SSH, server reach, the updater (Sparkle) and the empty-workspace
    /// repair (built here when no window's content built it first).
    func postNonPaintServices(on startup: StartupScheduler) {
        serviceStartPosts().post(on: startup)
        let attest = FreeTierAttestStarter(build: environment.build, bundle: .main, apiBaseURL: FeedService.apiBaseURL(auth: cloudAuth), settings: settings, signedIn: { [weak self] in self.map { $0.cloudAuth.isSignedIn || $0.cloudAuth.isRestoring } ?? true })
        LaunchServicePosts.nonPaint(freeTierAttest: { attest.start() }, ssh: { [weak self] in self?.ssh.start() }, serverReach: { [weak self] in self?.serverReach.start() },
                                    updater: { [weak self] in self?.updater.start(); DebugTimings.markLaunch("launch.non_paint_services") },
                                    emptyWorkspaceRepair: { [weak self] in _ = self?.emptyWorkspaces }).post(on: startup)
    }

    /// The service starts `init` used to make, one post each (p08-startup-031; startup-DESIGN.md section 5, S6
    /// to S10). `init` keeps their wiring: the updater's and the tips' closures, the Restart cmux-tui… binding,
    /// the no-activate keyboard guard and the notifications' `services`.
    func serviceStartPosts() -> LaunchServicePosts {
        LaunchServicePosts.serviceStarts(windowOcclusion: { [weak self] in self?.surfaceInvariant.observeWindowOcclusion() },
                                         inputVerification: { [weak self] in if let self { input.start(services: self) } },
                                         notifications: { [weak self] in self?.notifications.start() },
                                         updaterWork: { [weak self] in self?.updater.startAttachedWork() },
                                         serverUpdates: { [weak self] in self?.serverUpdates.start() },
                                         browserHost: { [weak self] in self?.startBrowserHost() })
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

    /// The platform services (p08-startup-029). Now, before the windows build and the restore mounts a page:
    /// what the first frame or the restore reads (the glass mode, the notification preferences and the Chief
    /// pet that takes arrivals, the updater's settings, so `Updater.start` runs on the person's schedule and
    /// ring, and the hibernation the restored pages report their hides to). Then one post each: the hot keys
    /// (`hotKeys` false: an agent- or bench-launched build never takes the person's system-wide keys), the
    /// border and glass follows after the first frame; the rest after startup.
    func startPlatformServices(settings: SettingsController, on startup: StartupScheduler, hotKeys: Bool) {
        LaunchStart.glass.runNow(on: startup) { seedGlass() }
        LaunchStart.notificationPreferences.runNow(on: startup) { notifications.preferences = settings.snapshot.notifications; notifications.followChiefPet(settings) }
        LaunchStart.updaterSettings.runNow(on: startup) { updater.follow(settings) }
        LaunchStart.hibernation.runNow(on: startup) { startHibernation(settings: settings) }
        let with = { (body: @escaping @MainActor @Sendable (AppServices, SettingsController) -> Void) -> @MainActor @Sendable () -> Void in
            { [weak self, weak settings] in if let self, let settings { body(self, settings) } } }
        LaunchServicePosts.platform(globalHotKeys: hotKeys ? { [weak self] in self?.globalHotKeys.start() } : nil,
                                    borders: { [weak self] in self?.observeBorders() }, glass: { [weak self] in self?.observeGlass() },
                                    keepAwake: with { KeepAwakeService.shared.start(settings: $1, store: $0.daemon.store) },
                                    mobile: with { $0.mobile.follow($1, launch: $0.environment.launch) }, notifications: with { $0.notifications.follow($1) },
                                    macScreenSettings: with { $0.followMacScreenSettings($1) }, deviceHub: with { $0.startDeviceHub($1) },
                                    computerUseHelper: with { services, settings in ComputerUseHelperDaemon.shared.follow(settings, disabledByPolicy: { [weak services] in services?.registry.disabledFeatures.contains(.computerUse) ?? true }) },
                                    hibernationMeasurements: { [weak self] in self?.startHibernationMeasurements() },
                                    apps: { [weak self] in self?.apps.start() }, macScreen: { [weak self] in self?.macScreenPages.activate() },
                                    updateFeed: { [weak self] in if let self { self.updateFeedObservation = UpdateFeedPosting.follow(self) } }).post(on: startup)
    }

    /// Runs one launch start by its class (p06-scheduler-049, `LaunchStart`): a first-frame start now, in its launch-turn
    /// signpost; another as an afterStartup post on ``launchStartup`` with feature `launchStartDeferral`, else now.
    /// With no launch scheduler (a test's services) it runs now and reads no feature.
    func runLaunchStart(_ start: LaunchStart, _ work: @escaping @MainActor @Sendable () -> Void) {
        guard let launchStartup else { return work() }
        start.run(on: launchStartup, deferring: start.startClass == .afterReveal && features.isEnabled(.launchStartDeferral), work)
    }

    /// The front window's focused pane shows an agent chat (`agentSession` is a conversation's only) that opens in WebKit.
    private var showsWebKitAgentChat: Bool { windows.active?.focusedPane?.selectedTab?.agentSession != nil && AgentPaneView.newPagesShowInWebKit(
        chromiumChat: AgentPaneTunables.chromium.value, hosting: webUI.chromium) }
}
