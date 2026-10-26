import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextPopups
import CmuxNextSettings
import CmuxNextWakeups
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    /// The daemon's first connect attempt, begun in `main`.
    let daemonPrestart: DaemonPrestart?
    /// The launch load-in, region by region; its last region revealing ends the startup phase's
    /// `launching` (made here, the composition root, and passed by init).
    let launchReveal: LaunchReveal
    /// The startup trace `CMUX_TRACE_STARTUP` asked for (nil: none): launch phases record their slices in it.
    private let startupTrace: StartupTrace?
    /// The app's daemon wire counters, made in `main` (nil in a release build).
    let wireStats: DaemonWireStats?
    /// The first live terminal frame (or no daemon): deferrable warm-up waits for it.
    let launchSettle: LaunchSettle
    /// The startup phase's settle references (first snapshot, restore, visible page).
    let startupReferences: StartupReferences
    /// Launch work that starts after the first window frame (perf-launch-memory).
    let firstFrame = FirstFrameGate()
    /// Cleanup deferred until the launch settles (injected; tests pass their own).
    let launchCleanup: LaunchCleanup
    /// The app's blocking-work lanes and the last quit's pages and composers, read on them since `main`.
    let launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake)
    /// Set in applicationDidFinishLaunching; nil before it (no IUO).
    var services: AppServices?
    /// A second quit signal's exit (`QuitSignal`): the Home cache's last write, bounded, then the end.
    lazy var forcedQuitExit = ForcedQuitExit(prepare: { [weak self] in
        self?.services?.crashRecovery.applicationWillTerminate()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
        self?.services?.home.applicationWillTerminate()
    }, save: { [weak self] in
        await self?.services?.home.flushCacheForQuit()
    })
    var settings: SettingsController?
    /// The app's one main-thread scheduler (budget, input check, task signposts, starvation guard), handed to control and services.
    let mainWork: MainWorkScheduler
    /// The main-thread budget's run-loop turn meter; `main` hands it to the application before `run()`.
    var turnMeter: MainTurnMeter { mainWork.budget.turns }
    let control: AppControl
    let mouseSideButtons = MouseSideButtons()
    var cloudContext: Task<Void, Never>?
    /// OSC 52 clipboard reads on the local daemon (`TerminalClipboardReadService`).
    var daemonPrompts: DaemonPrompts?
    /// The binding table's Ghostty keybinds, kept current (GHOSTTY-CONFIG).
    var ghosttyKeybinds: GhosttyKeybindSync?
    /// Watches the exact Ghostty files libghostty loaded and reloads them live.
    var ghosttyConfigLiveReload: GhosttyConfigLiveReload?
    /// The system's handler for other apps' sign-ins (`WebAuthSessionHandler`, which owns their broker).
    var webAuthHandler: WebAuthSessionHandler?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    init(environment: AppEnvironment, daemonPrestart: DaemonPrestart?, wireStats: DaemonWireStats?,
         startupTrace: StartupTrace? = nil,
         launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake),
         launchCleanup: LaunchCleanup = LaunchCleanup(cleanUpDownloadTempFiles: { BrowserDownloadTempFiles.shared.cleanUpLeftovers() })) {
        self.environment = environment
        self.launchReads = launchReads
        self.daemonPrestart = daemonPrestart
        self.startupTrace = startupTrace
        self.wireStats = wireStats
        self.launchCleanup = launchCleanup
        // One display link per display, shared by the app, window and budgeted frame schedulers.
        let displays = DisplayClock()
        FrameScheduler.install(displays: displays)
        // The launch's phases (p06-scheduler-006/007): background work waits for the reveal, idle
        // work for the settle. The marks are queued first, so each shows before the held work it opens.
        let startup = StartupPhase()
        startup.whenReached(.revealed) { DebugTimings.markLaunch("launch.revealed") }
        startup.whenReached(.settled) { DebugTimings.markLaunch("launch.settled") }
        let reveal = LaunchReveal(onRevealed: { [startup] in startup.noteFirstFrame() })
        launchReveal = reveal
        // The agent pages' warm-up page is done at the settle: their first page made its own process by now.
        launchSettle = LaunchSettle(reveal: reveal, imageHold: .shared, onSettle: { AgentPaneView.finishWarmup() })
        startupReferences = StartupReferences(startup: startup, reveal: reveal)
        let starvation = RenderStarvationGuard(holdsWork: false, signposts: true) // holds work once FeatureList is in the app (p12-perf-process-091)
        let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(), signposts: true, starvation: starvation),
                                         displays: displays, startup: startup)
        starvation.watch(mainWork.frames, FrameScheduler.app)
        self.mainWork = mainWork
        control = AppControl(mainWork: mainWork)
        super.init()
    }

    /// The launch: each domain's groups of calls (registerX in `Startup/Startup+<Domain>.swift`) and its
    /// single calls, in launch order, with the launch marks between them.
    func applicationDidFinishLaunching(_ notification: Notification) {
        registerProcess()
        DebugTimings.markLaunch("did_finish_launching_start")
        let launchStart = startupTrace?.uptimeNanos
        DebugTimings.install(watchdog: control.watchdog, startupTrace: startupTrace)
        defer {
            DebugTimings.markLaunch("did_finish_launching_end")
            if let launchStart { startupTrace?.task("did_finish_launching", start: launchStart) }
        }
        registerPlatformLaunch()
        let settingsRead = registerSettingsRead()
        DebugTimings.markLaunch("dfl.settings_read")
        registerTheme()
        registerPageRoots()
        DebugTimings.markLaunch("dfl.theme")
        let services = registerServices()
        DebugTimings.markLaunch("dfl.services")
        registerActions(services: services)
        registerTerminal(services: services)
        DebugTimings.markLaunch("dfl.bind")
        let settings = registerSettings(services: services, launch: settingsRead)
        let acpmux = registerChatSettings(services: services, settings: settings)
        registerKeepAwakeAndMobile(services: services, settings: settings)
        registerHomeFeeds(services: services, settings: settings, acpmux: acpmux)
        registerManagedPreferencesWatch(settings: settings)
        registerConfigActionsAndHotKeys(services: services, settings: settings)
        registerBrowserTabPreferences(services: services, settings: settings)
        WorkspaceAutoNameWiring(services: services).start(settings: settings) // `workspaces.autoName.variant` persist (hq#1957)
        BrowserOmnibarPreference.follow(settings, cache: services.cache)
        registerSystemFollows(services: services, settings: settings)
        registerTerminalTheme(services: services, settings: settings)
        services.remoteLocalhost.follow(settings)
        services.bookmarks.follow(settings)
        services.apps.start()
        registerControl(services: services, settings: settings)
        services.newTabSpares.prewarm() // the first agent page loads while the windows build (cx-z9kz0)
        DebugTimings.markLaunch("dfl.settings")
        NSApp.mainMenu = MainMenu.make(registry: services.registry, blocking: services.blocking)
        DebugTimings.markLaunch("dfl.menu")
        registerDaemon(services: services)
        DebugTimings.markLaunch("dfl.daemon_cloud_updater")
        registerFirstWindowHooks(services: services)
        let profilesDirectory = registerBrowserProfiles(services: services)
        DebugTimings.markLaunch("dfl.first_window_hooks")
        registerHomePage(services: services)
        registerInputBindings(services: services)
        registerBrowserData(services: services, profilesDirectory: profilesDirectory)
        DebugTimings.markLaunch("dfl.home_history")
        services.windows.restoreWhenLoaded()
        DebugTimings.markLaunch("dfl.windows")
        registerWindowChrome(services: services)
        // The runtime pack check wires the engine reason at once; its download waits until asked. After two
        // quick unexpected ends in a row, Chromium starts only when the user reloads a browser tab.
        services.startChromiumRuntime()
        firstFrame.whenOpen { [weak services] in services?.startLaterTabWarmups() }
        registerExternalOpen(services: services)
        // A launch whose first window never draws (no window, a daemon that never answers) still
        // starts the work waiting for that frame.
        firstFrame.armBackstop(after: .seconds(3))
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
        services?.externalOpen.continueActivity(type: userActivity.activityType, webpageURL: userActivity.webpageURL) ?? false
    }

    /// One route for every URL macOS hands cmux (`OpenedURLRouting`): the
    /// sign-in callback to Cloud auth first, in every form auth accepts,
    /// then `ExternalOpenRouter`.
    private func routeOpenedURL(_ url: URL) {
        guard let services else { return }
        let auth = services.cloud.auth
        let destination = OpenedURLRouting.route(url, isAuthCallback: { auth.isCallback($0) }, open: { services.externalOpen.open($0) })
        guard destination == .auth else { return }
        Task { _ = await auth.handleCallback(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.crashRecovery.applicationWillTerminate()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
        ComputerUseHelperDaemon.shared.applicationWillTerminate()
        services?.viewers.diffPages.terminate()
        services?.viewers.markdownPages.terminate()
        services?.viewers.editorPages.terminate()
        // Design mode's Home composer files left by cards still in a draft (BrowserDesignModeTempFiles).
        BrowserDesignModeController.tempFiles.removeAll()
        services?.home.applicationWillTerminate()
        services?.vscodeServeWeb.terminateForAppExit()
        cloudContext?.cancel()
        services?.cloud.stop()
        for session in services?.machines.cloud ?? [] { session.disconnect() }
        services?.ssh.stop()
        services?.serverReach.stop()
        control.stop()
        services?.configActions.stop()
        services?.globalHotKeys.stop()
        settings?.stop()
        services?.mobile.stop()
        services?.iphone.stop()
        services?.daemon.shutdownConnection()
    }

    /// The app stays running with no windows (standard macOS behavior): a window closes when its
    /// last workspace closes, and the daemon keeps every terminal regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click with no window open: the last closed window comes back
    /// with its workspaces, else a new window (in background mode a panel or the menu bar item may count as visible).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let services, !hasVisibleWindows || services.background.isBackground else { return true }
        services.windows.reopenOrCreateWindow()
        return false
    }
}
