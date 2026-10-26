import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLaunch
import CmuxNextPalette
import CmuxNextTerminal
import CmuxNextWakeups
import os

// Launch calls for the process, the services, the actions, the menu, the daemon, the first window and
// window restore. `applicationDidFinishLaunching` calls each domain's registerX in the launch's order; the
// `DebugTimings` marks between them stay there (plans/cmux-next/chrome-parity/p08-startup.md, task 014).
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
    }

    /// AppServices, the frame rate classes, the startup settle references, hang reports and Debug Settings.
    func registerServices() -> AppServices {
        let services = AppServices(environment: environment, launchReveal: launchReveal, work: launchReads.work, mainWork: mainWork,
                                   launchImages: launchReads.images, relaunchWake: launchReads.wake, wireStats: wireStats, inputTap: inputTap)
        AppProcessRoot.shared.adopt(services)
        self.services = services
        // Frame rate classes (p03-rendering-013): links at their clients' rate, loops at 30 Hz.
        let rateClasses = services.features.isEnabled(.frameRateClasses)
        FrameScheduler.appDisplays.followsClientRates = rateClasses
        DesignSettings.shared.loopsFollowFrameRate = rateClasses
        services.startEnergy()  // before any tab: WebKit, KeepAwake and the video wallpaper start from the inputs
        // The settle references, one closure each, before the daemon starts and the windows restore
        // (Chrome's StartupObserver, after_startup_task_utils.cc). A hidden launch (no window on
        // screen) reveals at once.
        let startup = mainWork.startup
        startup.noteLaunch(NSApp.isHidden ? .hidden : .window)
        services.daemon.store.whenFirstSnapshotApplied { startup.markDone(.firstSnapshot) }
        let references = startupReferences
        references.watchUnavailable { [daemon = services.daemon] in daemon.startup.isUnavailable }
        services.cache.presentationChanges.subscribe("startup-references") { [weak references] in references?.noteContentChange() }
        let windows = services.windows
        windows.onRestored = { [weak references, weak windows] in
            references?.restored { [weak windows] in windows?.visiblePageLoad() ?? .idle }
        }
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
        services.palette.bindRegistryActions()
    }

    /// App activation, the launch settle, OSC 52 prompts, the daemon, managed feature policy and Cloud.
    func registerDaemon(services: AppServices) {
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        WindowActivation.activateApp()
        // The launch settles on the first live terminal frame, or when the local daemon is unavailable.
        launchSettle.install(isUnavailable: { [daemon = services.daemon] in daemon.startup.isUnavailable })
        TerminalTimings.onContentApplied = { [weak self] in
            TerminalTimings.onContentApplied = nil
            DebugTimings.markLaunch("first_terminal_content_applied")
            // Ghostty presents on its own layer in this commit.
            CATransaction.setMainCompletion {
                DebugTimings.markLaunch("first_terminal_frame")
                self?.launchSettle.firstTerminalFrame()
            }
        }
        daemonPrompts = DaemonPrompts.start(services)
        services.daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                              resolvesShellIntegration: environment.resolvesShellIntegration, prestart: daemonPrestart)
        FeaturePolicyEnforcer(services: services).start()
        cloudContext = services.startCloud()
        firstFrame.whenOpen { [weak services] in services?.startNonPaintServices() }
        // Before the first window opens (restoreWhenLoaded opens one at once).
        services.windows.onPresent = { [weak services] controller in
            services?.crashRecovery.showRestartNotice(on: controller.window)
        }
    }

    /// First-window hooks and the idle warm-ups (palette, icon picker, cleanup, open panel).
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
                self?.firstFrame.open()
            }
        }
        // Once the first terminal frame is drawn, the palette panel is made
        // at the next idle moment, so the first open costs what later opens
        // cost (a launcher panel opens in one frame), without
        // delaying that frame.
        // Then the icon picker (its panel, page and symbol catalog), so the first Set Icon opens warm.
        launchSettle.whenSettled { [palette = services.palette, weak services] in
            Self.preparePalette(palette, step: 0) { IdleOnce().schedule { services?.iconPicker.prepare() } }
        }
        // Temporary download files a crash left in an earlier run (only the
        // recorded ones; the record is read and the files deleted off the
        // main actor). Downloads of this run are never touched.
        launchCleanup.schedule(on: launchSettle)
        // The system file picker made ahead at the first idle moment, so the first click is not cold.
        services.openPanel.warmWhenIdle(after: launchSettle.whenSettled)
        services.palette.onPresented = { DebugTimings.palettePresented($0) }
        // The key-down that opens the palette (a synthesized one under `debug.key`), for its input stage.
        services.palette.openingEventTimestamp = { [inputDispatch = services.inputDispatch] in
            let event = inputDispatch.event
            return event?.type == .keyDown ? event?.timestamp : nil
        }
        services.iconPicker.onOpened = { DebugTimings.iconPickerOpened($0) }
    }

    /// The mouse's back and forward buttons and the keybindings file.
    func registerInputBindings(services: AppServices) {
        mouseSideButtons.start { [weak services] in _ = services?.registry.perform($0 == .back ? "focusHistoryBack" : "focusHistoryForward") }
        services.keybindingsFile.start()
    }

    /// One palette warm-up step per idle moment (`PaletteController.prepare`), then `done`.
    private static func preparePalette(_ palette: PaletteController?, step: Int, done: @escaping @MainActor () -> Void) {
        IdleOnce().schedule {
            guard let palette, palette.prepare(step: step) else { return done() }
            preparePalette(palette, step: step + 1, done: done)
        }
    }
}
