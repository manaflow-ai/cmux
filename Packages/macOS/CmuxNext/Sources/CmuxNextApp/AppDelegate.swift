import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompatAppKit
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextInput
import CmuxNextLaunch
import CmuxNextMemory
import CmuxNextPages
import CmuxNextWebUpdates
import CmuxNextPalette
import CmuxNextPhoneAccess
import CmuxNextPopups
import CmuxNextSettings
import CmuxNextSignposts
import CmuxNextTerminal
import CmuxNextWakeups
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    /// The local daemon's Team ID and first connect attempt, made on the system lane in `main`.
    let daemonStart: LaunchRead<DaemonLaunchStart>
    /// The launch load-in, region by region; its last region revealing ends the startup phase's
    /// `launching` (made here, the composition root, and passed by init).
    let launchReveal: LaunchReveal
    /// The startup trace `CMUX_TRACE_STARTUP` asked for (nil: none): launch phases record their slices in it.
    private let startupTrace: StartupTrace?
    /// The app's daemon wire counters, made in `main` (nil in a release build without field data opt-in).
    let wireStats: DaemonWireStats?
    /// The launch's feature list from the composition root (``AppServices/launchFeatures(_:)``).
    let features: FeatureList?
    /// The first live terminal frame (or no daemon): reveals the pane region and, with the launch images, starts the control socket.
    let launchSettle: LaunchSettle
    /// An unavailable daemon's settle: every phase reference and startup ref it ends.
    let startupReferences: StartupReferences
    /// The launch's order owners, made in `main`: every deferred launch task is a post to `order.startup`.
    let order: LaunchOrder
    /// The agent panes' launch images, one startup ref while any shows.
    let launchImageHold: LaunchImageHold
    /// Cleanup deferred until startup completes (injected; tests pass their own).
    let launchCleanup: LaunchCleanup
    /// The app's blocking-work lanes and the last quit's pages and composers, read on them since `main`.
    let launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, frames: TerminalLaunchFrames, wake: AgentPaneRelaunchWake)
    /// cmux-next.json and the managed layers, read on the files lane since `main` (p08-startup 025).
    private let settingsRead: SettingsController.PendingLaunchRead
    /// Set in applicationDidFinishLaunching; nil before it (no IUO).
    var services: AppServices?
    /// URLs and Handoff activities macOS handed over before the services existed (the settings read still in flight).
    let launchOpens = LaunchOpenQueue()
    /// A second quit signal's exit (`QuitSignal`): the Home cache's last write, bounded, then the end.
    lazy var forcedQuitExit = ForcedQuitExit(prepare: { [weak self] in
        self?.services?.crashRecovery.applicationWillTerminate()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
        self?.services?.home.applicationWillTerminate()
    }, save: { [weak self] in
        await self?.services?.home.flushCacheForQuit()
    })
    var settings: SettingsController?
    /// The control socket bound on a lane after the settings launch read (feature `controlSocketEarlyBind`, AppControl.beginBind).
    var controlSocket: ControlSocketBind?
    /// The app's one main-thread scheduler (budget, input check, task signposts, starvation guard), handed to control and services.
    let mainWork: MainWorkScheduler
    /// The main-thread budget's run-loop turn meter; `main` hands it to the application before `run()`.
    var turnMeter: MainTurnMeter { mainWork.budget.turns }
    let control: AppControl
    /// The one input tap (p04-input.md 3 (A)), made in `main`: pending input, control and services
    /// observe it; `main` installs it on the application before `run()`.
    let inputTap: InputEventTap
    let mouseSideButtons: MouseSideButtons
    /// OSC 52 clipboard reads on the local daemon (`TerminalClipboardReadService`).
    var daemonPrompts: DaemonPrompts?
    /// The binding table's Ghostty keybinds, kept current (GHOSTTY-CONFIG).
    var ghosttyKeybinds: GhosttyKeybindSync?
    /// Watches the exact Ghostty files libghostty loaded and reloads them live.
    var ghosttyConfigLiveReload: GhosttyConfigLiveReload?
    /// The system's handler for other apps' sign-ins (`WebAuthSessionHandler`, which owns their broker).
    var webAuthHandler: WebAuthSessionHandler?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    /// `watchdog` is the launch's main-thread watchdog, made and started first in `main()`.
    init(environment: AppEnvironment, daemonStart: LaunchRead<DaemonLaunchStart>, wireStats: DaemonWireStats?, features: FeatureList? = nil,
         startupTrace: StartupTrace? = nil, order: LaunchOrder, watchdog: MainThreadWatchdog, inputTap: InputEventTap,
         settingsRead: SettingsController.PendingLaunchRead,
         launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, frames: TerminalLaunchFrames, wake: AgentPaneRelaunchWake),
         launchCleanup: LaunchCleanup = LaunchCleanup(cleanUpDownloadTempFiles: { BrowserDownloadTempFiles.shared.cleanUpLeftovers() })) {
        (self.environment, self.launchReads, self.settingsRead) = (environment, launchReads, settingsRead)
        (self.daemonStart, self.startupTrace) = (daemonStart, startupTrace)
        (self.wireStats, self.features) = (wireStats, features)
        self.launchCleanup = launchCleanup
        self.order = order
        launchImageHold = LaunchImageHold(startup: order.startup)
        // The launch's phase (made in main with the main-thread scheduler) reveals at the first frame.
        let startup = order.mainWork.startup
        let reveal = LaunchReveal(onRevealed: { [startup] in startup.noteFirstFrame() })
        // The restore ref and one ref per visible pane: one instance, on the launch's scheduler.
        let paneRefs = VisiblePaneRefs(startup: order.startup, mainWork: order.mainWork, phase: startup)
        (launchReveal, launchSettle) = (reveal, LaunchSettle(reveal: reveal, paneRefs: paneRefs))
        startupReferences = StartupReferences(startup: startup, reveal: reveal, mainWork: order.mainWork, paneRefs: paneRefs)
        (self.mainWork, self.inputTap) = (order.mainWork, inputTap)
        control = AppControl(mainWork: order.mainWork, input: inputTap, watchdog: watchdog)
        mouseSideButtons = MouseSideButtons(input: inputTap)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The critical phase begins: stalls from here name it (the run-loop turn this runs in stays one watchdog turn).
        control.watchdog.beginCriticalPhase()
        defer { control.watchdog.endStartupStep() }
        registerProcess()
        DebugTimings.markLaunch("did_finish_launching_start")
        let launchStart = startupTrace?.uptimeNanos
        DebugTimings.install(watchdog: control.watchdog, startupTrace: startupTrace)
        registerPlatformLaunch()
        // The rest runs with main()'s settings read, now or when it lands (the startup's main hop, unbudgeted):
        // no wait, no frame in the defaults (p08-startup 025). The launch marks end where the launch work ends.
        settingsRead.whenRead(hop: .userVisible, startup: order.startup, take: { [logger, features] read in
            DebugTimings.markLaunch("dfl.settings_wait")  // the read in hand: at once warm, after the disk cold
            if let failure = read.bootstrapFailure { logger.error("cmux-next config bootstrap failed: \(failure, privacy: .public)") }
            // cmux.json's appearance goes on the Ghostty overrides; the first config builds with them on a files lane and the launch goes on when it lands.
            TerminalThemeSetting.prime(read.snapshot)
            // The Kitty image budget per screen before the first config builds: with memorySmallAppStores sized from this Mac's memory.
            GhosttyRuntime.shared.setImageStorageBytesPerScreen(GhosttyImageStorageBudget.startingBytes(memoryBudget: SubsystemBudget.forThisMac(gpuResidentAvailable: false).kittyImageBytesPerSurface, sizedFromMemory: features?.isEnabled(.memorySmallAppStores) == true))
        }, then: { [self] read in GhosttyRuntime.shared.start(loadingOn: GhosttyLaneConfigLoader(work: launchReads.work, mainWork: mainWork)) { [self] in finishLaunching(settings: read, launchStart: launchStart) } })
    }

    /// The launch steps that need the settings, run after the settings launch read's take (`applicationDidFinishLaunching`):
    /// each domain's groups of calls (registerX in `Startup/Startup+<Domain>.swift`: Core, Settings, Platform) and its single calls, in launch
    /// order, with the launch marks between them (p08-startup task 014).
    private func finishLaunching(settings settingsRead: SettingsController.LaunchRead, launchStart: UInt64?) {
        DebugTimings.markLaunch("dfl.settings_read")
        // Chrome colors derive from the Ghostty theme; load it before any window.
        ThemeBridge.start(store: ThemeScope.app.store)
        // The diff page's files live in the app bundle (markdown-viewer/webviews-app).
        PageDescriptor.registerDiffRoot()
        PageDescriptor.registerFilePageRoots()
        PageDescriptor.registerAgentActivityRoot()
        DebugTimings.markLaunch("dfl.theme")
        let services = registerServices(launch: settingsRead)
        DebugTimings.markLaunch("dfl.services")
        AppActions.bindAtLaunch(services, on: order.startup)  // critical `AppActions.bind`: keys work from the first frame
        services.palettes.bindRegistryActions()  // the palette itself is built after the first frame, or by the first palette key
        registerTerminal(services: services)
        DebugTimings.markLaunch("dfl.bind")
        let settings = registerSettings(services: services, launch: settingsRead)
        // The platform services: what the first frame or the restore reads now, the rest posted.
        services.startPlatformServices(settings: settings, on: order.startup, hotKeys: !environment.isolatedLaunch)
        services.followEnergySaver(settings)
        registerSavedPicture(services: services, settings: settings)
        registerHomeFeeds(services: services, settings: settings)
        order.startup.post(.afterFirstFrame, "ConfigActions.start", on: .main) { [weak services, weak settings] in
            if let settings { services?.configActions.start(settings: settings) }  // cmux.json's custom actions for the palette and menus
        }
        // What an engine reads when it makes a page or starts, before any does (managed policy included).
        services.cache.browserTabs.preference.follow(settings, on: services.mainWork)
        services.lifetimeFollowers += BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, chromium: services.cache.chromium, on: services.mainWork)
        order.startup.post(.afterFirstFrame, "WorkspaceAutoName.start", on: .main) { [weak services, weak settings] in
            if let services, let settings { WorkspaceAutoNameWiring(services: services).start(settings: settings) }  // `workspaces.autoName.variant` persist (hq#1957)
        }
        services.lifetimeFollowers += BrowserOmnibarPreference.follow(settings, cache: services.cache, on: services.mainWork)
        // The look of the first frame: the loaded theme, background and backdrop art, then each workspace's theme and the app accent.
        order.startup.post(.critical, "TerminalTheme.follow", on: .main) { services.terminalTheme.follow(settings) }
        order.startup.post(.critical, "Themes.start", on: .main) { services.themes.start(); services.themes.followChromeTheme(settings) }
        services.bookmarks.follow(settings)
        registerControl(services: services, settings: settings)
        DebugTimings.markLaunch("dfl.settings")
        MainMenu.install(registry: services.registry, blocking: services.blocking, decidedKey: services.decidedKey, on: order.startup)  // critical `MainMenu.make`
        DebugTimings.markLaunch("dfl.menu")
        registerDaemon(services: services)
        DebugTimings.markLaunch("dfl.daemon_cloud_updater")
        registerFirstWindowHooks(services: services)
        let profilesDirectory = BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
        services.browserProfiles.load(directory: profilesDirectory, importStore: services.onboarding.importStore)
        DebugTimings.markLaunch("dfl.first_window_hooks")
        services.home.startWorkspace()  // the restore's first workspace waits for ensure_home; the Chief owner is a feed post
        order.startup.post(.afterFirstFrame, "MouseSideButtons.start", on: .main) { [weak self, weak services] in
            self?.mouseSideButtons.start { [weak services] in _ = services?.registry.perform($0 == .back ? "focusHistoryBack" : "focusHistoryForward") }
        }
        order.startup.post(.afterFirstFrame, "KeybindingsFile.start", on: .main) { [weak services] in services?.keybindingsFile.start() }
        registerBrowserData(services: services, profilesDirectory: profilesDirectory)
        DebugTimings.markLaunch("dfl.home_history")
        services.windows.restoreWhenLoaded(paneRefs: launchSettle.paneRefs)
        DebugTimings.markLaunch("dfl.windows")
        // After two quick unexpected ends in a row, Chromium starts only
        // when the user reloads a browser tab.
        // The runtime pack check wires the engine reason at once; its download waits until asked.
        services.startChromiumRuntime()
        services.postLaterTabWarmups(on: order.startup)
        registerExternalOpen(services: services)
        // The registered launch work ends the implicit ref. The first window is made in this turn, or
        // on the launch snapshot read's end (`restoreWhenLoaded`), so its commit ends the first-frame ref; a launch that shows none
        // completes at the scheduler's failsafe, with reason `failsafe`.
        order.startup.finishRegistration()
        DebugTimings.markLaunch("did_finish_launching_end")
        DebugTimings.armFirstIdleMark()
        if let launchStart { startupTrace?.task("did_finish_launching", start: launchStart) }
    }

    /// Every quit (Cmd-Q, the Quit menu, the Dock, `cmux app quit`, power
    /// off) goes through `QuitCoordinator`: it may ask whether to keep the
    /// local terminals (which run in cmux-tui and outlive the app), folds in
    /// the incognito close confirmation, saves windows, and for End stops
    /// the local daemon. `kill` never gets here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        services?.quit.shouldTerminate(sender) ?? .terminateNow
    }

    /// Chromium's `CommandDispatcher` asks NSApp.delegate (in Chrome, its `AppController`) to
    /// validate a `commandDispatch:` item that no Chromium window handles, with no
    /// `respondsToSelector:` check first. Chrome enables only the commands its AppController can
    /// run with no browser window; cmux has no AppController, so those commands are disabled
    /// (enabled, AppKit would send the command where nothing runs it). Any other action is one
    /// this delegate implements, which AppKit enables when it has no validator.
    @objc(validateUserInterfaceItem:) func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action != Selector(("commandDispatch:")) && item.action != Selector(("commandDispatchUsingKeyModifiers:"))
    }

    /// Web, `ssh:` and `x-man-page:` links (cmux as their handler) open as
    /// tabs; links in this build's scheme (`cmux://tab/…`) run `link.open`;
    /// `<scheme>://auth-callback` from the browser fallback of sign-in goes
    /// to Cloud auth.
    @objc(handleURLEvent:reply:) func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        routeOpenedURL(url)
    }

    /// Files opened with cmux (every document type in Info.plist) and URLs delivered
    /// without an Apple event, routed like the Apple event's.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { routeOpenedURL(url) }
    }

    /// Handoff of a web page (cmux as the default browser, Info.plist
    /// `NSUserActivityTypes`): it opens as a browser tab, like a link.
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        userActivityType == NSUserActivityTypeBrowsingWeb
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let services else {
            // Before the services exist (the settings read in flight): kept, then continued by the launch.
            guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else { return false }
            launchOpens.hold(.activity(type: userActivity.activityType, webpageURL: userActivity.webpageURL))
            return true
        }
        return services.externalOpen.continueActivity(type: userActivity.activityType, webpageURL: userActivity.webpageURL)
    }

    /// One route for every URL macOS hands cmux (`OpenedURLRouting`): the
    /// sign-in callback to Cloud auth first, in every form auth accepts,
    /// then `ExternalOpenRouter`.
    func routeOpenedURL(_ url: URL) {
        guard let services else { return launchOpens.hold(.url(url)) }  // routed when the launch builds them
        let auth = services.cloudAuth
        let destination = OpenedURLRouting.route(url, isAuthCallback: { auth.isCallback($0) }, open: { services.externalOpen.open($0) })
        guard destination == .auth else { return }
        Task { _ = await auth.handleCallback(url) }  // it starts Cloud first (`CloudAuth.onSignIn`)
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.crashRecovery.applicationWillTerminate()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
        ComputerUseHelperDaemon.shared.applicationWillTerminate()
        services?.viewers.diffPages.terminate()
        services?.viewers.markdownPages.terminate()
        services?.viewers.editorPages.terminate()
        // This launch's design mode Home composer files left by cards still in a draft (BrowserDesignModeTempFiles).
        BrowserDesignModeController.tempFiles.removeAll()
        services?.home.applicationWillTerminate()
        services?.vscodeServeWeb.terminateForAppExit()
        services?.stopCloud()
        services?.madeSSH?.stop()
        services?.serverReach.stop()
        controlSocket?.discard()  // a socket bound at launch that never served
        control.stop()
        services?.configActions.stop()
        services?.globalHotKeys.stop()
        settings?.stop()
        services?.mobile.stop()
        services?.iphone.stop()
        services?.daemon.shutdownConnection()
    }

    /// The app stays running with no windows (standard macOS behavior); the daemon keeps every terminal regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Secure coding for any restorable state (as chrome/browser/app_controller_mac.mm); every cmux window is `isRestorable = false`.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Dock click with no window open: the last closed window comes back
    /// with its workspaces, else a new window (in background mode a panel or the menu bar item may count as visible).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let services, !hasVisibleWindows || services.background.isBackground else { return true }
        services.windows.reopenOrCreateWindow()
        return false
    }
}
