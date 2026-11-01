import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextKeepAwake
import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextWebUpdates
import CmuxNextPalette
import CmuxNextPhoneAccess
import CmuxNextPopups
import CmuxNextServer
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextUpdater
import CmuxNextWakeups
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    /// The daemon's first connect attempt, begun in `main`.
    private let daemonPrestart: DaemonPrestart?
    /// The first live terminal frame (or no daemon): deferrable warm-up waits for it.
    private let launchSettle = LaunchSettle()
    /// Launch work that starts after the first window frame (perf-launch-memory).
    let firstFrame = FirstFrameGate()
    /// Cleanup deferred until the launch settles (injected; tests pass their own).
    private let launchCleanup: LaunchCleanup
    /// The app's blocking-work lanes and the last quit's pages and composers, read on them since `main`.
    private let launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake)
    /// Set in applicationDidFinishLaunching; nil before it (no IUO).
    private var services: AppServices?
    private let openedURLs = OpenedURLDelivery()
    /// A second quit signal's exit (`QuitSignal`): the Home cache's and the state files' last writes, bounded, then the end.
    private lazy var forcedQuitExit = Self.secondSignalExit { [weak self] in self?.services }

    /// The exit's steps: `prepare` waits on no disk, so the deadline is armed at once; the state files' queued
    /// saves are awaited beside the Home cache's write, after it (tests inject the deadline and the end).
    static func secondSignalExit(_ services: @escaping @MainActor () -> AppServices?, armDeadline: ((Duration) -> Void)? = nil,
                                end: (@MainActor () -> Void)? = nil) -> ForcedQuitExit {
        ForcedQuitExit(prepare: {
            services()?.crashRecovery.applicationWillTerminate()
            AppProcessRoot.shared.hangReports?.applicationWillTerminate()
            services()?.home.applicationWillTerminate()
        }, save: {
            guard let services = services() else { return }
            async let files: Void = services.stateFilesDrained()
            await services.home.flushCacheForQuit()
            await files
        }, armDeadline: armDeadline, deadlineEnd: services()?.quitDeadlineEnd(), end: end)
    }
    private var settings: SettingsController?
    /// The app's one main-thread scheduler for budgeted work: its per-frame budget, with the
    /// person's pending-input check and task signposts. Built here, the composition root, and
    /// handed to the control socket and the services.
    private let mainWork: MainWorkScheduler
    private let control: AppControl
    private let mouseSideButtons = MouseSideButtons()
    private var cloudContext: Task<Void, Never>?
    /// OSC 52 clipboard reads on the local daemon (`TerminalClipboardReadService`).
    var daemonPrompts: DaemonPrompts?
    /// The binding table's Ghostty keybinds, kept current (GHOSTTY-CONFIG).
    private var ghosttyKeybinds: GhosttyKeybindSync?
    /// Watches the exact Ghostty files libghostty loaded and reloads them live.
    private var ghosttyConfigLiveReload: GhosttyConfigLiveReload?
    /// The system's handler for other apps' sign-ins (`WebAuthSessionHandler`, which owns their broker).
    private var webAuthHandler: WebAuthSessionHandler?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    init(environment: AppEnvironment, daemonPrestart: DaemonPrestart?,
         launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake), launchCleanup: LaunchCleanup = LaunchCleanup()) {
        self.environment = environment
        self.launchReads = launchReads
        self.daemonPrestart = daemonPrestart
        self.launchCleanup = launchCleanup
        let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(), signposts: true))
        self.mainWork = mainWork
        control = AppControl(mainWork: mainWork)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        DebugTimings.markLaunch("did_finish_launching_start")
        DebugTimings.install()
        defer { DebugTimings.markLaunch("did_finish_launching_end") }
        // No system caret bubble over cmux's own native text fields (before any field edits).
        NativeCaretAccessory.install()
        // Every window, shell or auxiliary, opens by one placement rule.
        WindowPlacement.noActivate = environment.noActivate
        WindowPlacement.testScreen = environment.testWindow?.screen
        // An agent launch must never come back by itself: without this, loginwindow reopens it at the
        // next login (without the agent's environment, so it activates and takes the tag's socket).
        if environment.noActivate { NSApp.disableRelaunchOnLogin() }
        // A `cmux` shim outside this app runs the CLI of the app opened last
        // (plans/cmux-next/version-skew.md); an isolated launch never claims it.
        if LastAppCLIPointer.shouldPublish(environment: ProcessInfo.processInfo.environment),
           let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux").path {
            Task.detached(priority: .utility) { LastAppCLIPointer().publish(cliPath: cli) }
        }
        // cmux.json's appearance goes on the Ghostty overrides before the
        // runtime's first config load, so the first frame needs no reload.
        let settingsRead = SettingsController.readAtLaunch(
            fileURL: settingsFileURL(), buildDefaults: .channel(downloadsAutomatically: UpdateBuildIdentity.main().track.downloadsAutomaticallyByDefault))
        TerminalThemeSetting.prime(settingsRead.snapshot)
        // Before the import cards start (AppActions.bind): off at launch, they never scan or resume.
        BrowserImportGate.prime(settingsRead.snapshot)
        DebugTimings.markLaunch("dfl.settings_read")
        // Chrome colors derive from the Ghostty theme; load it before any window.
        ThemeBridge.start(store: ThemeScope.app.store)
        // The glass tint and the Desktop Wallpaper background follow the desktop picture.
        BackdropImageStore.shared.desktop.start()
        // The diff page's files live in the app bundle (markdown-viewer/webviews-app).
        PageDescriptor.registerDiffRoot()
        PageDescriptor.registerFilePageRoots()
        PageDescriptor.registerAgentActivityRoot()
        DebugTimings.markLaunch("dfl.theme")
        let services = AppServices(environment: environment, keyWindowSource: { NSApp.keyWindow }, appActiveSource: { NSApp.isActive },
                                   heldKeyReplay: { event, _, _ in NSApp.sendEvent(event) }, work: launchReads.work, mainWork: mainWork,
                                   launchImages: launchReads.images, relaunchWake: launchReads.wake, peerApprover: PeerApprovalsApp.approver())
        AppProcessRoot.shared.adopt(services)
        self.services = services
        // Where each agent chat rests, beside the snapshot, so a relaunch reopens it there (cx-6bgzj).
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent(), files: services.agentPaneStateFiles)
        #if DEBUG
        services.windowRecord.watchLaunch() // `--record-launch`: before the first window is made
        #endif
        // Hangs, lag spikes and opt-in hang reports (WatchdogReporting); the controller lives with the process.
        AppProcessRoot.shared.adopt(hangReports: WatchdogReporting.install(control.watchdog, services: services))
        services.quit.watchdog = control.watchdog
        DebugTimings.markReveal(services.launchReveal)
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        services.debugSettings.start()
        DebugTimings.markLaunch("dfl.services")
        AppActions.bind(services)
        HandlerCoverage.verify(services.registry)
        services.palette.bindRegistryActions()
        let ghosttyKeybinds = GhosttyKeybindSync(router: services.keyRouter)
        self.ghosttyKeybinds = ghosttyKeybinds
        ghosttyKeybinds.start()
        let ghosttyConfigLiveReload = GhosttyConfigLiveReload()
        self.ghosttyConfigLiveReload = ghosttyConfigLiveReload
        ghosttyConfigLiveReload.start()
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface.
        TerminalHooks(services: services).install()
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(services: services, launch: settingsRead)
        services.newTabSpares.prewarm() // the first agent page loads while the windows build (cx-z9kz0)
        DebugTimings.markLaunch("dfl.settings")
        NSApp.mainMenu = MainMenu.make(registry: services.registry, blocking: services.blocking)
        DebugTimings.markLaunch("dfl.menu")
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        WindowActivation.activateApp()
        launchSettle.install(daemon: services.daemon)
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
        DebugTimings.markLaunch("dfl.daemon_cloud_updater")
        services.windows.onFirstWindow = { [weak services] _ in
            #if DEBUG || CMUX_BENCH_HOOKS
            if let services, services.environment.showcase { _ = DebugShowcase.seed(["focus": .bool(false)], services: services) }
            #endif
            // An App Store request made while no window existed shows in this window (S22).
            if let apps = services?.apps, apps.isStoreWaiting { Task { @MainActor in apps.windowDidShowContent() } }
            // Recovered unsaved changes from a quit, crash or power-off (R96 quit hook).
            // And a chat's unsent text the last quit's deadline ended before it saved (AgentPaneStateLoss).
            if let window = services?.windows.active?.window, let drafts = services?.recoveryDrafts, let services {
                Task { @MainActor in
                    await RecoveryNotice.show(store: drafts, in: window)
                    await services.agentPaneStateLoss.showNotices(in: window, pairedSealCleared: { await services.iphone.pairedSealClearedForCutOff() })
                }
            }
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                    DebugTimings.markLaunch("first_window_frame_committed")
                    self?.firstFrame.open()
                }
            }
        }
        // Once the first terminal frame is drawn, the palette panel is made
        // at the next idle moment, so the first open costs what later opens
        // cost (a launcher panel opens in one frame), without
        // delaying that frame.
        // Then the icon picker (its panel, page and symbol catalog), so the first Set Icon opens warm.
        launchSettle.whenSettled { [palette = services.palette, weak services] in
            Self.preparePalette(palette, step: 0) { IdleOnce.schedule { services?.iconPicker.prepare() } }
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
        let profilesDirectory = BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
        services.browserProfiles.load(directory: profilesDirectory, importStore: services.onboarding.importStore)
        DebugTimings.markLaunch("dfl.first_window_hooks")
        services.home.start()
        services.harnessIcons.start()
        mouseSideButtons.start { [weak services] in _ = services?.registry.perform($0 == .back ? "focusHistoryBack" : "focusHistoryForward") }
        services.keybindingsFile.start()
        services.bookmarks.start(directory: profilesDirectory, importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: profilesDirectory.deletingLastPathComponent())
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install()
        // Every cmux page view follows `browser.defaultEngine` (Chromium by default) through this one host.
        PageWebView.openPanel = services.openPanel
        PageWebView.chromiumHosting = ChromiumPageHost(
            cef: services.cache.cef,
            preference: { [weak services] in
                services?.settings?.snapshot.browserDefaultEngine ?? services?.cache.browserTabs.preference.defaultEngine ?? .fallback
            },
            keyRouter: services.keyRouter) { [weak services] page in
            // A pane's own Chromium page (the applier's childWindowTab; not a nested one, the Home dock's Channels) attached after it showed: the focus model applies again (W1, W4).
            let pane = page.window.flatMap { window in services?.windows.owner(of: window) }?.content?.panes.values.first { pane in (page.chromiumPage as? CEFPageChromiumPage).map { pane.currentContent?.childWindowTab === $0.tab } == true }
            if let pane, pane.workspace?.isParked == false { pane.workspace?.focus.send(.contentPresented(pane: pane.paneKey)) }
            return pane != nil
        }
        DebugTimings.markLaunch("dfl.home_history")
        services.windows.restoreWhenLoaded()
        DebugTimings.markLaunch("dfl.windows")
        // After two quick unexpected ends in a row, Chromium starts only
        // when the user reloads a browser tab.
        services.observeBorders()
        services.observeGlass()
        services.updateFeedObservation = UpdateFeedPosting.follow(services)
        // The runtime pack check wires the engine reason at once; its download waits until asked.
        services.startChromiumRuntime()
        firstFrame.whenOpen { [weak services] in services?.startLaterTabWarmups() }
        // Other apps' sign-ins, before any request a launch by one delivers.
        // The engines' incognito profiles and the Chromium engine's sign-in tabs (AppServices).
        let webAuthWindows = WebAuthSessionWindows(host: services, logger: services.daemon.logger,
                                                   profiles: services.browserStores.offTheRecord, signInCallbacks: services.signInCallbacks,
                                                   contextMenus: services.contextMenus, activeLook: services.activeLook)
        let webAuthHandler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: webAuthWindows))
        self.webAuthHandler = webAuthHandler
        WebAuthSessionHandler.install(webAuthHandler)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] in services?.externalOpen.flush(); services?.pageHostPool.windowDidAppear($0.window) }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
        // A launch whose first window never draws (no window, a daemon that never answers) still
        // starts the work waiting for that frame.
        openedURLs.start { [weak self] in self?.routeReadyURL($0) }
        firstFrame.armBackstop(after: .seconds(3))
    }

    /// One palette warm-up step per idle moment (`PaletteController.prepare`), then `done`.
    private static func preparePalette(_ palette: PaletteController?, step: Int, done: @escaping @MainActor () -> Void) {
        IdleOnce.schedule {
            guard let palette, palette.prepare(step: step) else { return done() }
            preparePalette(palette, step: step + 1, done: done)
        }
    }

    /// cmux.json, created on first launch.
    private func settingsFileURL() -> URL {
        do {
            return try CmuxConfigFile.prepareDefaultURL()
        } catch {
            logger.error("cmux-next config bootstrap failed: \(String(describing: error), privacy: .public)")
            return CmuxConfigFile.defaultURL()
        }
    }

    /// cmux-next.json settings and the tagged control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(services: AppServices, launch: SettingsController.LaunchRead) {
        // Start the web OTA launch check before any restored or prewarmed page can
        // request its entry document. Otherwise the entry can come from the app
        // bundle while later chunks come from the kept update tree.
        WebUpdates.shared.prepare(launch.snapshot.updates, bundle: .main)
        let registry = services.registry
        let settings = SettingsController(registry: registry, fileURL: launch.fileURL, launch: launch)
        settings.applyManagedFeaturesNow()
        ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloud.auth).start()
        self.settings = settings
        services.settings = settings
        UserOnlySettingConfirmation.install(settings, services: services)
        // Every palette-exposed schema setting in the palette (R93).
        services.palette.sources.settings = SettingsPaletteSource(settings: settings, themes: services.themes.catalog) { [weak services] in
            services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
        }
        services.history.startDaemonSync(settings: settings)
        services.locationTrail.watchScope(settings: settings)
        let shortcutEditor = PaletteShortcutEditor(services: services, settings: settings)
        services.paletteShortcutEditor = shortcutEditor
        services.palette.shortcutRecorder.editor = shortcutEditor
        // Managed-settings status for MDM tooling (osquery, Fleet, Jamf), plans/cmux-next/enterprise.md.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        settings.writeManagedStatus(
            to: ManagedStatusReport.defaultURL(bundleID: bundleID),
            context: ManagedStatusReport.Context(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                bundleID: bundleID
            )
        )
        settings.start(announcingDiagnostics: true)
        AppProcessRoot.shared.hangReports?.start(settings: settings, asks: services.machineAsks, firstWindow: { [firstFrame] in await firstFrame.opened() })
        // An attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) keeps its owner's chat settings.
        let acpmux = QuitAgents.environment(services)
        ChatSettingsPush.start(settings: settings, socketPath: acpmux?.isAttached == true ? nil : acpmux?.socketPath)
        KeepAwakeService.shared.start(settings: settings, store: services.daemon.store)
        services.mobile.follow(settings, launch: services.environment.launch, configureAdmission: services.iphone.followPhoneAccess)
        services.chatsFeed?.keepCurrent()
        services.projectsImport.start(feed: services.chatsFeed)
        if let feed = services.chatsFeed { AgentPageChats.wire(services.agentTabs, to: feed, opener: services.chatsOpener) }
        AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        AgentPageChats.wireSandbox(services.agentTabs, services: services)
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
        // macOS posts no notification when an MDM profile changes; activation
        // is the event-driven backstop next to the managed-file watchers. A full-screen window an
        // update relaunch kept back enters once the user is in cmux (`enterRestoredFullScreens`).
        Task { [weak settings, weak services] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                settings?.managedPreferencesMayHaveChanged()
                services?.windows.enterRestoredFullScreens()
                await services?.paidPlanReturned() // an upgrade's payment page sends the person back here
                await services?.joinConsent.refresh() // a consent refusal acpmux recorded meanwhile; reads nothing with Labs off
            }
        }
        services.configActions.start(settings: settings)
        services.personInput.start()
        services.joinConsent.follow(settings: settings)
        // Agent-launched builds never take system-wide keys from the person's app.
        if !environment.noActivate { services.globalHotKeys.start() }
        // Nor a menu bar item: a tagged build an agent launches leaves the person's menu bar alone.
        if !environment.noActivate { services.menuBarExtra.follow(settings, background: services.background) }
        services.cache.browserTabs.preference.follow(settings)
        BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, cef: services.cache.cef)
        WorkspaceAutoNameWiring(services: services).start(settings: settings) // `workspaces.autoName.variant` persist (hq#1957)
        BrowserOmnibarPreference.follow(settings, cache: services.cache)
        services.notifications.follow(settings)
        services.followMacScreenSettings(settings)
        services.startDeviceHub(settings)
        services.updater.follow(settings)
        ComputerUseHelperDaemon.shared.follow(settings, disabledByPolicy: { [weak services] in
            services?.registry.disabledFeatures.contains(.computerUse) ?? true
        })
        services.computerUsePreview.follow(settings)
        services.startHibernation(settings: settings)
        services.autoArchive.start() // workspaces.autoArchive: first pass 30 s after launch
        services.workspaceHibernation.start() // workspaces.hibernation: first pass 60 s after launch
        services.terminalTheme.follow(settings)
        services.themes.start()
        services.themes.followChromeTheme(settings)
        services.remoteLocalhost.follow(settings)
        // A Cloud machine's localhost (Open Desktop, or a machine whose cmux-tui has no loopback
        // forward) goes over the app's own WireGuard tunnel, as in cmux Classic.
        services.remoteLocalhost.cloudTunnelSocket = services.cloud.tunnelSocket
        services.bookmarks.follow(settings)
        services.apps.start()
        Task {
            await settings.waitForLoad(atLeast: 1); await launchSettle.settled(within: .seconds(4)) // control socket: after the first frames (cx-z9kz0)
            // `app.quitBehavior: "end"` (first release) is now "end-keep-layout".
            _ = try? await settings.migrateLegacyQuitBehavior()
            _ = try? await settings.migrateLegacyWorkspaceRowKeys() // `sidebar.showWorkspaceDirectory` / `showCounts` move to `sidebar.workspaceRow.*`
            _ = try? await settings.migrateLegacyPaneToolbarButtons() // `tabs.hiddenButtons` becomes `tabs.toolbarButtons`
            // Classic cmux keys next reads under another name (`ClassicSettingRename`).
            _ = try? await settings.migrateClassicSettings()
            // Shortcuts and settings classic cmux's Settings kept in its preferences (`ClassicShortcutImport`, `ClassicPreferenceImport`).
            _ = try? await settings.importClassicShortcuts(marker: .standard)
            _ = try? await settings.importClassicPreferences(marker: .standard)
            do {
                try control.start(registry: registry, settings: settings, launch: environment.launch, services: services)
                control.registerCloudMethods(services)
                control.registerAccountsMethods(services)
                control.registerBillingMethods(services)
                control.registerRemoteMethods(services)
                control.registerMobileMethods(services)
                control.registerUpdateMethods(services.updater, services: services)
                control.registerInputMethods(services)
                control.registerSettingsDebugMethods(services)
                control.registerPageDebugMethods(services)
                control.registerRemoteBrowserDebugMethods(services)
                RemoteViewDebugMethods(services: services).register(on: control.service?.router)
                services.registerMacScreenDebug(on: control.service?.router)
                services.registerDeviceHubDebug(on: control.service?.router)
                DebugNowPlaying.register(on: control.service?.router, services: services)
                DebugDownloads.register(on: control.service?.router, services: services)
                DebugCEFDevToolsLayout.register(on: control.service?.router, services: services)
                #if DEBUG
                // The Chromium host app prototype (browserHost.helperPrototype; cef-helper-app-DESIGN.md).
                let chromiumHost = ChromiumHostPrototype { ChromiumHostPrototype.bundledConfiguration() }
                control.service?.router.register([
                    .mainActor("debug.chromium_host") { [weak services] call in
                        let controller = services?.windows.controllers.first
                        let pane = (call.params["pane"]?.stringValue ?? controller?.focus.state.pane).flatMap { controller?.content?.paneController(key: $0) }
                        let fields = chromiumHost.handle(op: call.params["op"]?.stringValue, url: call.params["url"]?.stringValue,
                                                         over: pane?.view.contentHost, focus: call.params["focus"]?.boolValue != false)
                        return .value(JSONValue(foundation: fields) ?? .null)
                    },
                    .async("debug.chromium_host.measure") { call in
                        guard let fields = await chromiumHost.measure(op: call.params["op"]?.stringValue, count: call.params["count"]?.intValue)
                        else { return ["error": "no running Chromium host"] }
                        return .object(fields.mapValues(JSONValue.number))
                    }.withDeadline(.fixed(.seconds(60))),
                ])
                #endif
                DebugBrowserExternal.register(on: control.service?.router, services: services)
                DebugCloudMove.register(on: control.service?.router, services: services)
                DebugTerminalLinks.register(on: control.service?.router, services: services)
                if let router = control.service?.router {
                    // The passkey hand-off: an agent's request waits for the person's banner click.
                    let passkeys = BrowserPasskeyRequests(host: AppBrowserPasskeyHost(services: services))
                    services.notifications.onPasskeyBanner = { id in Task { _ = try? await passkeys.answer(id) } }
                    BrowserPageService(engine: AppBrowserPageEngine(services: services), passkeys: passkeys,
                                       agentMouse: { [weak settings] in
                                           await MainActor.run { settings?.snapshot.browserAgentMouse } ?? AgentMouseSetting().fallback
                                       }, mirrors: services).install(on: router)
                    services.apps.attach(router: router)
                }
                logger.info("control socket \(self.control.socketPath ?? "", privacy: .public)")
            } catch {
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
            // Share This Mac resumes when the person left it on.
            services.macScreenPages.activate()
        }
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
    @objc(handleURLEvent:reply:) private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
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
        services?.input.endRelaunchBehind("handoff")
        return services?.externalOpen.continueActivity(type: userActivity.activityType, webpageURL: userActivity.webpageURL) ?? false
    }

    /// One route for every URL macOS hands cmux (`OpenedURLRouting`): the
    /// sign-in callback to Cloud auth first, in every form auth accepts,
    /// then `ExternalOpenRouter`.
    private func routeOpenedURL(_ url: URL) { openedURLs.receive(url) }

    private func routeReadyURL(_ url: URL) {
        guard let services else { return }
        // Something the user opened with cmux: an update relaunch's startup ends, so it can come forward.
        services.input.endRelaunchBehind("external open")
        let auth = services.cloud.auth
        let destination = OpenedURLRouting.route(url, isAuthCallback: { auth.isCallback($0) }, open: { services.externalOpen.open($0) })
        guard destination == .auth else { return }
        Task {
            guard await !auth.handleCallback(url) else { return }
            await auth.awaitRestored()
            guard auth.signInFailed, !auth.isSignedIn, !auth.isSigningIn else { return }
            try? services.settingsWindow.show(section: .accounts)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.crashRecovery.applicationWillTerminate()
        services?.crashReporting.reporter.stallSummary.close()  // the open hour's stall counts
        // The release push's socket closes and nothing reconnects (ReleasePushListener).
        services?.updater.stopReleasePush()
        services?.agentTabs.pageChats.stopNotices()
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
        // A Dock click in an update relaunch's startup: the user chose cmux.
        services?.input.endRelaunchBehind("dock click", activating: true)
        guard let services, !hasVisibleWindows || services.background.isBackground else { return true }
        services.windows.reopenOrCreateWindow()
        return false
    }
}
