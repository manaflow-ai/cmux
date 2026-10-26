import AppKit
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLaunch
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextWakeups
import os

// Launch calls for the process, the services, the actions, the daemon, the first window and its
// hooks. `finishLaunching` calls each domain's registerX in the launch's order; the `DebugTimings`
// marks between them stay there (plans/cmux-next/chrome-parity/p08-startup.md, task 014).
extension AppDelegate {
    /// Design mode's crash leftovers, the quit signals and the main-thread watchdog.
    func registerProcess() {
        // Design mode files a crash left (BrowserDesignModeTempFiles); off the main thread.
        Task.detached(priority: .background) { BrowserDesignModeController.tempFiles.removeAll() }
        // SIGTERM, SIGINT and SIGHUP (dev tooling, `kill`, Ctrl-C) are
        // "Quit, keep sessions" with no alert.
        QuitSignal.install(quit: { [weak self] in
            guard let services = self?.services else { return NSApp.terminate(nil) }
            services.quit.terminateFromSignal()
        }, forceExit: { [weak self] in
            self?.forcedQuitExit.start()
        })
        control.startWatchdog()
        (NSApp as? CmuxApplication)?.inputQueueing = control.watchdog
    }

    /// AppServices, the control socket's bind, the frame rate classes, the startup settle references, hang
    /// reports and Debug Settings.
    func registerServices(launch settingsRead: SettingsController.LaunchRead) -> AppServices {
        let services = AppServices(environment: environment, launchReveal: launchReveal, work: launchReads.work, mainWork: mainWork,
                                   launchImages: launchReads.images, relaunchWake: launchReads.wake, wireStats: wireStats, inputTap: inputTap,
                                   launchImageHold: launchImageHold, launchStartup: order.startup, crashKeys: control.crashKeys)
        AppProcessRoot.shared.adopt(services)
        self.services = services
        controlSocket = AppControl.beginBind(features: services.features, settingsRead: settingsRead, launch: environment.launch,
                                             work: launchReads.work, mainWork: mainWork)  // p08-startup-019: on a lane
        TooltipPresenter.shared.appEvents = services.appEvents  // its inactive-app dismissal shares the app's one observer
        // Frame rate classes (p03-rendering-013): links at their clients' rate, loops at 30 Hz.
        let rateClasses = services.features.isEnabled(.frameRateClasses)
        FrameScheduler.appDisplays.followsClientRates = rateClasses
        DesignSettings.shared.loopsFollowFrameRate = rateClasses
        services.startEnergy()  // before any tab: WebKit, KeepAwake and the video wallpaper start from the inputs
        // VSyncHub (p03-rendering-014): each display's link on that display's vsync thread, one
        // coalesced main post per vsync. Off until the hop measurement is recorded (threading-model.md).
        if services.features.isEnabled(.vsyncHub) { FrameScheduler.appDisplays.hub = VSyncHub() }
        // The settle references, one closure each, before the daemon starts and the windows restore
        // (Chrome's StartupObserver, after_startup_task_utils.cc). A hidden launch (no window on
        // screen) reveals at once.
        let startup = mainWork.startup
        startup.noteLaunch(NSApp.isHidden ? .hidden : .window)
        services.daemon.store.whenFirstSnapshotApplied { startup.markDone(.firstSnapshot) }
        // The restore and visible-page references are the pane refs' (`VisiblePaneRefs.finishRestore`).
        startupReferences.watchUnavailable { [daemon = services.daemon] in daemon.startup.isUnavailable }
        // Hangs, lag spikes and opt-in hang reports (WatchdogReporting); the controller lives with the process.
        AppProcessRoot.shared.adopt(hangReports: WatchdogReporting.install(control.watchdog, services: services))
        services.quit.watchdog = control.watchdog
        DebugTimings.markReveal(services.launchReveal)
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        services.debugSettings.start()
        return services
    }

    /// The registry's action handlers, their coverage check and the palette's registry actions.
    func registerActions(services: AppServices) {
        AppActions.bind(services)
        HandlerCoverage.verify(services.registry)
        services.palettes.bindRegistryActions()  // the palette itself is built after the first frame, or by the first palette key
    }

    /// App activation, the launch settle, OSC 52 prompts, the daemon, managed feature policy and Cloud's post.
    func registerDaemon(services: AppServices) {
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        WindowActivation.activateApp()
        launchSettle.install(daemon: services.daemon, warmup: services.agentPageWarmup)
        daemonPrompts = DaemonPrompts.start(services)
        services.startLocalDaemon(prestart: daemonPrestart)  // the painted terminal colors first (OSC 10/11/12)
        FeaturePolicyEnforcer(services: services).start()
        services.postCloudStart(on: order.startup)  // no Cloud restore or connect before the first frame (p08-startup 020)
        services.postNonPaintServices(on: order.startup)
        // Before the first window opens (restoreWhenLoaded opens one at once).
        services.windows.onPresent = { [weak services] controller in
            DebugTimings.markLaunch("first_window_presented")  // launch.first_window ends here (once per process)
            services?.crashRecovery.showRestartNotice(on: controller.window)
        }
    }

    /// First-window hooks and the afterStartup warm-ups (palette, icon picker, open panel) and cleanup.
    func registerFirstWindowHooks(services: AppServices) {
        services.windows.onFirstWindow = { [weak services] _ in
            #if DEBUG || CMUX_BENCH_HOOKS
            if let services, services.environment.showcase { _ = DebugShowcase.seed(["focus": .bool(false)], services: services) }
            #endif
            // An App Store request made while no window existed shows in this window (S22).
            if let apps = services?.apps, apps.isStoreWaiting { Task { @MainActor in apps.windowDidShowContent() } }
            // Recovered unsaved changes from a quit, crash or power-off (R96 quit hook).
            if let window = services?.windows.active?.window, let drafts = services?.recoveryDrafts {
                Task { @MainActor in await RecoveryNotice.show(store: drafts, in: window) }
            }
            CATransaction.setMainCompletion { [weak self] in
                DebugTimings.markLaunch("first_window_frame_committed")
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

    /// The mouse's back and forward buttons and the keybindings file.
    func registerInputBindings(services: AppServices) {
        mouseSideButtons.start { [weak services] in _ = services?.registry.perform($0 == .back ? "focusHistoryBack" : "focusHistoryForward") }
        services.keybindingsFile.start()
    }
}
