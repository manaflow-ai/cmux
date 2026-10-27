import CmuxNextAgentPane
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
        LaunchServicePosts.nonPaint(freeTierAttest: { [weak self] in if let self, let follow = attest.start(on: self.mainWork) { self.lifetimeFollowers.append(follow) } }, ssh: { [weak self] in self?.ssh.start() }, serverReach: { [weak self] in self?.serverReach.start() },
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
                                         updaterWork: { [weak self] in if let self { updater.startAttachedWork(appEvents: appEvents) } },
                                         serverUpdates: { [weak self] in self?.serverUpdates.start() },
                                         browserHost: { [weak self] in self?.startBrowserHost() })
    }

    /// Warm-ups for later tabs (WebKit for agent pages, Chromium, the New Tab spare, page preloads), the agent tab
    /// import and the right sidebar's icons (on the cpu lane; a panel built first posted them already), through
    /// ``LaterTabWarmups`` on this app (`AppServices+LaterTabWarmupHost`). No WebKit view is made by these before
    /// startup completes (p08-startup-042). The warm-up makes no WebKit page when a shown agent tab made its view
    /// or agent pages open in Chromium (`AgentPageWarmup.start(webUI:)` decides when it runs).
    func postLaterTabWarmups(on startup: StartupScheduler) {
        LaterTabWarmups(host: self).posts().post(on: startup)
    }

    /// The platform services (p08-startup-029). Now, before the windows build and the restore mounts a page:
    /// what the first frame or the restore reads (the glass mode, the notification preferences and the Chief
    /// pet that takes arrivals, the updater's settings, so `Updater.start` runs on the person's schedule and
    /// ring, and the hibernation the restored pages report their hides to). Then one post each: the hot keys
    /// (`hotKeys` false: an agent- or bench-launched build never takes the person's system-wide keys), the
    /// border and glass follows after the first frame; the rest after startup.
    func startPlatformServices(settings: SettingsController, on startup: StartupScheduler, hotKeys: Bool) {
        seedGlass()
        notifications.preferences = settings.snapshot.notifications
        notifications.followChiefPet(settings)
        updater.follow(settings)
        startHibernation(settings: settings)
        // Each start has its own declared type: one expression with every closure inline (and a ternary closure)
        // was too much for the type checker ("failed to produce diagnostic").
        typealias Start = @MainActor @Sendable () -> Void
        func with(_ body: @escaping @MainActor @Sendable (AppServices, SettingsController) -> Void) -> Start {
            { [weak self, weak settings] in if let self, let settings { body(self, settings) } }
        }
        var hotKeyStart: Start?
        if hotKeys { hotKeyStart = { [weak self] in self?.globalHotKeys.start() } }
        let bordersStart: Start = { [weak self] in self?.observeBorders() }
        let glassStart: Start = { [weak self] in self?.observeGlass() }
        let keepAwakeStart = with { services, settings in KeepAwakeService.shared.start(settings: settings, store: services.daemon.store, on: services.mainWork) }
        let mobileStart = with { services, settings in services.mobile.follow(settings, launch: services.environment.launch) }
        let notificationsStart = with { services, settings in services.notifications.follow(settings) }
        let macScreenSettingsStart = with { services, settings in services.followMacScreenSettings(settings) }
        let deviceHubStart = with { services, settings in services.startDeviceHub(settings) }
        let computerUseHelperStart = with { services, settings in
            ComputerUseHelperDaemon.shared.follow(settings, mainWork: services.mainWork, lanes: services.work, disabledByPolicy: { [weak services] in
                services?.registry.disabledFeatures.contains(.computerUse) ?? true
            })
        }
        let hibernationMeasurementsStart: Start = { [weak self] in self?.startHibernationMeasurements() }
        let appsStart: Start = { [weak self] in self?.apps.start() }
        let macScreenStart: Start = { [weak self] in self?.macScreenPages.activate() }
        let updateFeedStart: Start = { [weak self] in
            guard let self else { return }
            updateFeedObservation = UpdateFeedPosting.follow(self)
        }
        LaunchServicePosts.platform(globalHotKeys: hotKeyStart, borders: bordersStart, glass: glassStart, keepAwake: keepAwakeStart, mobile: mobileStart,
                                    notifications: notificationsStart, macScreenSettings: macScreenSettingsStart, deviceHub: deviceHubStart,
                                    computerUseHelper: computerUseHelperStart, hibernationMeasurements: hibernationMeasurementsStart,
                                    apps: appsStart, macScreen: macScreenStart, updateFeed: updateFeedStart).post(on: startup)
    }
}
