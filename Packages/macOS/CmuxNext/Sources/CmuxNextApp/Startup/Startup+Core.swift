import AppKit
import CmuxNextBrowser
import CmuxNextCompatAppKit
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSignposts
import CmuxNextWakeups

// Launch calls for the services, the daemon, the first window and its
// hooks. `finishLaunching` calls each domain's registerX in the launch's order; the `DebugTimings`
// marks between them stay there (plans/cmux-next/chrome-parity/p08-startup.md, task 014).
extension AppDelegate {
    /// AppServices, the control socket's bind, the frame rate classes, the startup settle references, hang
    /// reports and Debug Settings.
    func registerServices(launch settingsRead: SettingsController.LaunchRead) -> AppServices {
        let services = AppServices(environment: environment, launchReveal: launchReveal, work: launchReads.work, mainWork: mainWork,
                                   launchImages: launchReads.images, terminalLaunchFrames: launchReads.frames, relaunchWake: launchReads.wake, wireStats: wireStats, inputTap: inputTap,
                                   launchImageHold: launchImageHold, launchStartup: order.startup, crashKeys: control.crashKeys,
                                   watchdog: control.watchdog, features: features)
        AppProcessRoot.shared.adopt(services)
        self.services = services
        // Before any window mounts a pane; the ring and host takeover are stand-ins until 131 and 150 land.
        services.crashRecovery.relaunchReattach(features: services.features).apply(steps: .unavailable,
            discardSavedFrames: { services.terminalLaunchFrames.discardLaunchRead() }, mark: { DebugTimings.markLaunch($0) })
        controlSocket = AppControl.beginBind(features: services.features, settingsRead: settingsRead, launch: environment.launch,
                                             work: launchReads.work, mainWork: mainWork)  // On a lane
        TooltipPresenter.shared.follow(appEvents: services.appEvents, deadlines: .on(services.mainDeadlines))  // the app's one observer and wake-up queue
        CmuxToastCenter.shared.deadlines = .on(services.mainDeadlines)  // toasts' times are classed deadlines, behind input
        BrowserExternalApps.shared.queries = services.workspaceQueries  // a page's app links ask Launch Services on the system lane
        let rateClasses = services.features.isEnabled(.frameRateClasses)  // links at their clients' rate, loops at 30 Hz
        FrameScheduler.appDisplays.followsClientRates = rateClasses
        DesignSettings.shared.loopsFollowFrameRate = rateClasses
        LaunchStart.energy.runNow(on: order.startup) { services.startEnergy() }  // before any tab: WebKit, KeepAwake and the video wallpaper start from the inputs
        // VSyncHub: each display's link on that display's vsync thread, one
        // coalesced main post per vsync. Off until the hop measurement is recorded (threading-model.md).
        if services.features.isEnabled(.vsyncHub) { FrameScheduler.appDisplays.hub = VSyncHub() }
        // The settle references, one closure each, before the daemon starts and the windows restore
        // (Chrome's StartupObserver, after_startup_task_utils.cc). A hidden launch (no window on
        // screen) reveals at once and is interrupted: its first frame records no launch sample.
        let startup = mainWork.startup
        let presentation: StartupPhase.Presentation = NSApp.isHidden ? .hidden : .window
        startup.noteLaunch(presentation)
        if presentation != .window { DebugTimings.markLaunch(LaunchSlices.interruptedMark) }  // before the first window
        services.daemon.store.whenFirstSnapshotApplied { startup.markDone(.firstSnapshot) }
        // The restore and visible-page references are the pane refs' (`VisiblePaneRefs.finishRestore`).
        startupReferences.watchUnavailable { [daemon = services.daemon] in daemon.startup.isUnavailable }
        // Hangs, lag spikes and opt-in hang reports (WatchdogReporting); the controller lives with the process.
        AppProcessRoot.shared.adopt(hangReports: WatchdogReporting.install(control.watchdog, services: services))
        services.quit.watchdog = control.watchdog
        // Idle wakeups per inactive minute, once the launch's own work is done.
        order.startup.post(.afterStartup, "AppServices.startIdleWakeups", on: .main) { [weak services, control = self.control] in
            guard let services else { return }
            services.startIdleWakeups(watchdog: control.watchdog, hiddenWorkspaceMemory: AppProcessRoot.shared.hangReports?.memory)
            control.idleWakeups = services.idleWakeups  // the person's input ends an idle period at that input
        }
        DebugTimings.markReveal(services.launchReveal)
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        LaunchStart.debugSettings.runNow(on: order.startup) { services.debugSettings.start() }
        return services
    }

    /// The handler coverage check, app activation, the launch settle, OSC 52 prompts, the daemon, managed feature policy and Cloud's post.
    func registerDaemon(services: AppServices) {
        HandlerCoverage.verifyAtLaunch(services.registry)  // every handler is bound by now; Debug builds only
        order.startup.post(.critical, "WindowActivation.activateApp", on: .main) { WindowActivation.activateApp() }
        launchSettle.install(daemon: services.daemon, warmup: services.agentPageWarmup, windows: services.windows, on: services.mainWork)
        launchSettle.dropLaunchReads(frames: services.terminalLaunchFrames, pages: services.launchImages, features: services.features, images: launchImageHold)
        if services.features.isEnabled(.hiddenPollPause) {  // before the local daemon's first connect
            let presence = DaemonPresenceFeed(windows: services.appVisibility.shownWindows)
            services.lifetimeFollowers.append(presence)
            services.machines.connectionPresence = presence.presence
        }
        // The painted terminal colors first (OSC 10/11/12), and the prompts' side-event subscriptions before the connect.
        daemonPrompts = LaunchStart.localDaemon.runNow(on: order.startup) { services.startLocalDaemon(after: daemonStart) }
        let featurePolicyFollower = LaunchStart.featurePolicy.runNow(on: order.startup) { FeaturePolicyEnforcer(services: services).start() }
        services.lifetimeFollowers.append(featurePolicyFollower)
        services.postCloudStart(on: order.startup)  // no Cloud restore or connect before the first frame (p08-startup 020)
        services.postNonPaintServices(on: order.startup)
        // Before the first window opens (restoreWhenLoaded opens one at once): its indicators and its first
        // become-main notice find the config and resync follows running.
        StatusIndicatorAppearance.shared.observe(on: services.mainWork, appEvents: services.appEvents,
                                                 workspaceEvents: services.workspaceEvents)
        services.windows.onPresent = { [weak services] controller in
            DebugTimings.markLaunch("first_window_presented")  // launch.first_window ends here (once per process)
            services?.crashRecovery.showRestartNotice(on: controller.window)
        }
    }

    /// First-window hooks and the afterStartup warm-ups (palette, icon picker, open panel) and cleanup.
    func registerFirstWindowHooks(services: AppServices) {
        services.windows.onFirstWindow = { [weak services, startup = order.startup] first in
            #if DEBUG || CMUX_BENCH_HOOKS
            if let services, services.environment.showcase { _ = DebugShowcase.seed(["focus": .bool(false)], services: services) }
            #endif
            // An App Store request made while no window existed shows in this window (S22).
            if let apps = services?.apps, apps.isStoreWaiting { Task { @MainActor in apps.windowDidShowContent() } }
            // Recovered unsaved changes from a quit, crash or power-off (R96 quit hook).
            if let services, let window = services.windows.active?.window {
                RecoveryNotice.post(store: services.recoveryDrafts, in: window, on: startup, work: services.work, mainWork: services.mainWork)
            }
            CATransaction.setMainCompletion { [weak self, weak services, weak first] in
                DebugTimings.markLaunch("first_window_frame_committed")
                #if DEBUG || CMUX_BENCH_HOOKS
                // Before the gate: its later-tab warm-ups build panes. Structure only; the threads are read off main.
                if let services {
                    self?.control.startupReport.firstFrameCommitted(
                        contentSubviews: first?.window?.contentView?.subviews,
                        viewsBuilt: services.windows.controllers.reduce(0) { built, controller in
                            controller.mountedContents.reduce(built) { $0 + $1.panes.count }
                        },
                        readThreads: StartupReportRecorder.threadRead(on: services.work, replyOn: services.mainWork))
                }
                #endif
                self?.order.startup.firstFrameCommitted()
            }
        }
        // Once startup completes (the visible page loaded, the launch images went), one idle frame each: the palette's
        // panel and command page, so the first open costs what later opens cost (a launcher panel opens in
        // one frame); then the icon picker (its panel, page and symbol catalog), so the first Set Icon opens
        // warm; then the system file picker made ahead, so the first click is not cold.
        LaunchFirstOpenWarmups(paletteSteps: PaletteController.prepareStepNames, prewarmPaletteStrings: { PaletteController.prewarmStrings() },
                               preparePalette: { [weak services] in _ = services?.palette.prepare(step: $0) },
                               prepareIconPicker: { [weak services] in services?.iconPicker.prepare() },
                               warmOpenPanel: { [weak services] in services?.openPanel.warmWhenIdle() }).post(on: order.startup)
        services.palettes.postBuild(on: order.startup)
        // Temporary download files a crash left in an earlier run (only the
        // recorded ones; the record is read and the files deleted off the
        // main actor). Downloads of this run are never touched.
        launchCleanup.schedule(on: order.startup)
        services.iconPicker.onOpened = { DebugTimings.iconPickerOpened($0) }
    }
}
