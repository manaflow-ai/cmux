import AppKit
import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentIntegrations
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextKeepAwake
import CmuxNextKeys
import CmuxNextLiveCode
import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextWebUpdates
import CmuxNextPalette
import CmuxNextPopups
import CmuxNextServer
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextUpdater
import CmuxNextWakeups
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment
    /// Resolves once before any auth or daemon is constructed; cancelled on quit.
    private var cloudBootstrap: Task<Void, Never>?
    private let cloudEnvironment: Task<CloudEnvironmentBootstrap.LaunchRead, any Error>  // started in `main` (startAtLaunch)
    private var launchSnapshot: Task<LaunchSnapshotRead, Never>?  // started in `main` (readAtLaunch): the snapshot and the launch kind; nil once the launch took its result
    private var settingsTask: Task<SettingsController.LaunchRead, Never>? = SettingsController.startLaunchRead(buildDefaults: .thisBuild)
    /// The first live terminal frame (or no daemon), never before the first window frame: deferrable warm-up waits for it.
    private let launchSettle: LaunchSettle; private let launchHold: LaunchBackgroundHold  // launchHold: what nobody sees waits for the open workspace (CMUX-629)
    /// Launch work that starts after the first window frame (perf-launch-memory).
    let firstFrame: FirstFrameGate
    /// Cleanup deferred until the launch settles (injected; tests pass their own).
    private let launchCleanup: LaunchCleanup
    /// The app's blocking-work lanes and the last quit's pages and composers, read on them since `main`; stage 0's window (LaunchShell), planned there.
    private let launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake, chromium: CEFLaunchPrefetch, shell: LaunchShell)
    /// Set in applicationDidFinishLaunching; nil before it (no IUO).
    private var services: AppServices?
    private let openedURLs = OpenedURLDelivery()
    private lazy var appCopyGuide = AppCopyGuide(open: { [weak self] urls in for url in urls { self?.routeOpenedURL(url) } },
                                                 relaunching: { [weak self] in self?.services?.updater.willRelaunch?() })
    /// A second quit signal's exit (`QuitSignal`): the Home cache's and the state files' last writes, bounded, then the end.
    private lazy var forcedQuitExit = Self.secondSignalExit { [weak self] in self?.services }

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

    init(environment: AppEnvironment,
         launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake, chromium: CEFLaunchPrefetch, shell: LaunchShell),
         cloudEnvironment: Task<CloudEnvironmentBootstrap.LaunchRead, any Error>, launchSnapshot: Task<LaunchSnapshotRead, Never>, launchCleanup: LaunchCleanup = LaunchCleanup()) {
        self.environment = environment; self.cloudEnvironment = cloudEnvironment; self.launchSnapshot = launchSnapshot
        self.launchReads = launchReads; self.launchCleanup = launchCleanup; DebugTimings.markLaunch("main.delegate.fields") // after the stored properties' initial values
        let firstFrame = FirstFrameGate()
        self.firstFrame = firstFrame
        launchSettle = LaunchSettle(firstFrame: firstFrame); DebugTimings.markLaunch("main.delegate.first_frame_gate")
        let mainWork = MainWorkScheduler.app(budget: MainFrameBudget(input: SessionInputPending(), signposts: true))
        self.mainWork = mainWork; DebugTimings.markLaunch("main.delegate.main_work"); launchHold = LaunchBackgroundHold(budget: mainWork.budget) { DebugTimings.markLaunch($0) } // the hold: before anything queues background work
        control = AppControl(mainWork: mainWork); DebugTimings.markLaunch("main.delegate.control")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) { DebugTimings.markLaunch("app.did_finish_launching_entry"); launchReads.shell.show(title: Strings.appName) // stage 0's window, one commit
        // task-owner: cloudBootstrap; awaits stage 0's frame, then the CLI read `main` started (its cancel kills that CLI) before services, then the cache refresh after the first frame, cancelled at termination.
        cloudBootstrap = Task { [weak self, cloudEnvironment] in
            guard let self, let settingsTask else { return }; await launchReads.shell.framed()
            let read = await launchSnapshot?.value ?? LaunchSnapshotRead(snapshot: nil, kind: .unknown); launchSnapshot = nil; self.settingsTask = nil; DebugTimings.markLaunch("app.launch_snapshot_awaited"); if read.snapshot == nil { DebugTimings.markLaunch("launch.no_snapshot") }  // suspends for the read; the daemon's start reads no file. No snapshot: maybe the bare launch (piece 8); `read.kind` says whether it is
            do {
                let (selection, refresh) = try await withTaskCancellationHandler { try await cloudEnvironment.value } onCancel: { cloudEnvironment.cancel() }
                try Task.checkCancellation(); DebugTimings.markLaunch("cloud_env.awaited")
                environment.cloudConfiguration = CloudConfiguration.from(selection: selection, isDebugBuild: ControlService.isDebugBuild)
                environment.terminalEnvironment["CMUX_NEXT_CLOUD_RUNTIME"] = "1"
                environment.terminalEnvironment["CMUX_NEXT_CLOUD_ENV"] = selection.name
                environment.terminalEnvironment["CMUX_NEXT_CLOUD_BACKEND"] = selection.apiOrigin.absoluteString
                environment.terminalEnvironment["CMUX_PLATFORM_ORIGIN"] = selection.platformOrigin.absoluteString
                try await finishLaunching(read, settings: settingsTask.value); await firstFrame.opened(); await refresh()
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Cloud environment bootstrap failed: \(String(describing: error), privacy: .public)")
                // Keep the native app and local daemon usable when client-config is
                // unavailable. Never fall back to classic or pass a stale NEXT
                // backend to a daemon started from this launch.
                environment.cloudConfiguration = .unavailable
                for key in LaunchIdentity.cloudSelectionKnobs + ["CMUX_PLATFORM_ORIGIN"] {
                    environment.terminalEnvironment.removeValue(forKey: key)
                }
                try? await finishLaunching(read, settings: settingsTask.value) // only cancellation throws; Quit must not resume startup
            }
            cloudBootstrap = nil
        }
    }

    private func finishLaunching(_ launch: LaunchSnapshotRead, settings: SettingsController.LaunchRead) async throws { let launchSnapshot = launch.snapshot; try await LaunchTestDelay.atLaunch { DebugTimings.markLaunch($0) } // launch-tti.sh control=MS: a known wait before any window
        let preparedDaemon = DaemonService.prestart(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
            terminalEnvironmentProvider: environment.terminalEnvironmentProvider(prefersGhosttyTerm: { [weak self] in self?.services?.settings?.snapshot.terminalTerm == .xtermGhostty }),
            resolvesShellIntegration: environment.resolvesShellIntegration, echoesPlacementShift: true)
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
        // A tagged dev build opens on the built-in display (#51115); a screenshot launch's test screen wins.
        LaunchDisplay.current = environment.testWindow == nil ? environment.launchDisplay : nil
        // An agent launch must never come back by itself: without this, loginwindow reopens it at the
        // next login (without the agent's environment, so it activates and takes the tag's socket).
        if environment.noActivate { NSApp.disableRelaunchOnLogin() }
        // Other copies of this app: a second copy opened says which kept running; a passing copy offers a move.
        appCopyGuide.start(activates: !environment.noActivate, afterFrame: firstFrame.whenOpen)
        // cmux.json's appearance goes on the Ghostty overrides before the runtime's first config
        // load, so the first frame needs no reload; appearance.fontSmoothing before any window.
        let settingsRead = SettingsController.appliedAtLaunch(settings)
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
        self.services = services; services.launchReveal.pages.bind(firstFrame) { DebugTimings.markLaunch($0) } // no page view before the first frame (startup-tti)
        services.home.ensure.ensuresAtLaunch = true // before the restore asks: the launch waits for Home, which may start after the first frame
        // Where each agent chat rests, beside the snapshot, so a relaunch reopens it there (cx-6bgzj).
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent(), files: services.agentPaneStateFiles)
        #if DEBUG || CMUX_BENCH_HOOKS
        services.windowRecord.watchLaunch() // `--record-launch`: before the first window is made
        #endif
        // A launch harness's `layout.*` marks (LaunchLayoutSettle): before the first window is made.
        LaunchLayoutSettle.start(when: LaunchMarkSink.shared.isActive, isShell: { $0 is ShellWindow }, now: { DebugTimings.millisecondsSinceProcessStart() },
                                 write: { LaunchMarkSink.shared.write(name: $0, ms: $1) })
        // Hangs, lag spikes and opt-in hang reports (WatchdogReporting); the controller lives with the process.
        AppProcessRoot.shared.adopt(hangReports: WatchdogReporting.install(control.watchdog, services: services))
        services.quit.watchdog = control.watchdog
        DebugTimings.markReveal(services.launchReveal)
        services.launchReveal.firstFrame = firstFrame // the views' own launch work waits on it (FirstFrameHold)
        // This launch's times and stages (LaunchStages), in every build, for `cmux app launch-times` (CMUX-571): after the first frame, at Home's reveal or 10 s on (a relaunch into another workspace never shows Home).
        let binderLaps = LaunchBinderLaps()
        if let bundleID = environment.launch.bundleID, let file = LaunchTimesFile.app(bundleID: bundleID) {
            let recorder = LaunchTimesRecorder(file: file, work: services.work, info: Bundle.main.infoDictionary ?? [:], listen: AgentPaneLaunchTimings.shared.listen, marks: DebugTimings.launchMarkTimes, binders: binderLaps.times) { StagedUpdatePrewarm.consumeLaunchMarker(build: $0, bundleIdentifier: bundleID) }
            firstFrame.whenOpen { [launchReveal = services.launchReveal, weak services] in launchReveal.whenReady(.home, orAfter: .seconds(10)) { recorder.write(marks: DebugTimings.launchMarkTimes(), workspaces: services?.daemon.store.workspaces.count) } }
        }
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        services.debugSettings.start()
        DebugTimings.markLaunch("dfl.services")
        AppActions.bind(services, laps: binderLaps)
        DebugTimings.markLaunch("dfl.app_actions") // AppActions.bind alone; dfl.bind adds the palette, Ghostty keybinds and terminal hooks
        services.palette.bindRegistryActions()
        let ghosttyKeybinds = GhosttyKeybindSync(router: services.keyRouter)
        self.ghosttyKeybinds = ghosttyKeybinds
        ghosttyKeybinds.start()
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface.
        TerminalHooks(services: services).install()
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(services: services, launch: settingsRead)
        services.newTabSpares.prewarm() // the first agent page loads while the windows build (cx-z9kz0)
        DebugTimings.markLaunch("dfl.settings")
        if services.crashRecovery.recovery.startsUpdaterBeforeWindows { services.updater.start() } // a restart loop: before the daemon and windows, so a build that ends before its first frame can still fetch its fix
        NSApp.mainMenu = MainMenu.make(registry: services.registry, customizations: CustomizationsMenu.item(registry: services.registry, settings: { [weak services] in services?.settings },
            openAll: { [weak services] in try? services?.settingsWindow.show(section: nil, route: SettingsDeepLink.customizeRoute) }))
        DebugTimings.markLaunch("dfl.menu")
        WindowActivation.activateApp()
        launchSettle.install(daemon: services.daemon); launchHold.install(settled: launchSettle.whenSettled, firstFrame: firstFrame)
        daemonPrompts = DaemonPrompts.start(services)
        services.healthFeeds.start() // app health: before the daemon's first ensure
        let daemonPrestart = await withTaskCancellationHandler { await preparedDaemon.value } onCancel: { preparedDaemon.cancel() }
        guard !Task.isCancelled else { daemonPrestart?.cancel(); throw CancellationError() }
        services.daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(prefersGhosttyTerm: { [weak self] in self?.services?.settings?.snapshot.terminalTerm == .xtermGhostty }),
                              resolvesShellIntegration: environment.resolvesShellIntegration, prestart: daemonPrestart, launchSnapshot: launchSnapshot)
        FeaturePolicyEnforcer(services: services).start()
        // Labs > Live Code starts the live code watcher with the other non-paint services.
        firstFrame.whenOpen { [weak services, logger] in
            guard let services else { return }
            services.startNonPaintServices()
            services.liveCode.labsSwitch(services.settings?.snapshot.liveCode == true)
            HandlerCoverage.verify(services.registry)
            services.registry.logBindingProblems()
            logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        }
        firstFrame.whenOpen { [weak services] in services?.startPostFrameFeeds(); LaunchTypeProbe(environment: ProcessInfo.processInfo.environment) { DebugTimings.markLaunch($0) }?.type() } // launch-ready type=1
        // Before the first window opens (restoreWhenLoaded opens one at once).
        launchReads.shell.content.contentReady = services.launchReveal.whenContentReady // swap over stage 0 once regions show content
        services.windows.onPresent = { [weak services, shell = launchReads.shell] controller in
            services?.crashRecovery.showRestartNotice(on: controller.window); shell.presented(controller.window) // the first takes stage 0's frame, then its place
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
            DebugTimings.markLaunch("frame.commit_start"); CATransaction.setMainCompletion { [weak self] in
                DebugTimings.markLaunch("first_window_frame_committed")
                TerminalLaunchFrames.closeLaunches() // the terminals that asked by now are this frame's
                self?.firstFrame.open()
            }
        }
        // At idle after the first terminal frame: the palette panel (native), the icon catalog (off the main actor), then the hover card. The icon picker and
        // group editor (WebKit, ~60 MB of processes) wait for a menu or palette open, where every Set Icon and Rename Group is,
        // and are freed again once their idle limit passes with no open or menu (IconPickerService/GroupEditorService.idleLimit);
        // each menu or palette open makes them again or pushes that limit back.
        launchSettle.whenSettled { [palette = services.palette, weak services] in Self.preparePalette(palette, step: 0) { services?.hoverCards.warm() }; services?.iconPicker.prepare(page: false); services?.windows.recordSaver.launchImages.windowsChanged() }
        let warmOverlays = { @MainActor [weak services] in services?.iconPicker.prepare(); services?.groupEditor.prepare() }
        services.keyRouter.menuPickKeys.tracking.onMenus(warmOverlays)
        services.palette.onShows(warmOverlays)
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
        mouseSideButtons.start { [weak services] in _ = services?.registry.perform($0 == .back ? "focusHistoryBack" : "focusHistoryForward") }
        services.keybindingsFile.start(); services.machines.local.languagePacks.start()  // CMUX-570
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install()
        // Every cmux page view follows `browser.defaultEngine` (Chromium by default) through this one host.
        PageWebView.openPanel = services.openPanel
        PageWebView.chromiumHosting = ChromiumPageHost(
            cef: services.cache.cef,
            preference: { [weak services] in
                services?.settings?.snapshot.browserDefaultEngine ?? services?.cache.browserTabs.preference.defaultEngine ?? .fallback
            },
            keyRouter: services.keyRouter, healthFeed: services.healthFeeds.pageFeed) { [weak services] page in
            // A pane's own page (the one PageWebView.shown finds, as the applier's childWindowTab; not a nested one, the Home dock's Channels) changed the view that takes its keys (its Chromium page attached after it showed, or it moved to WebKit, its Chromium tab gone): the focus model applies again (W1, W4).
            let pane = page.window.flatMap { window in services?.windows.owner(of: window) }?.content?.panes.values.first { pane in if case .page(let view)? = pane.currentContent { PageWebView.shown(in: view.content) === page } else { (page.chromiumPage as? CEFPageChromiumPage).map { pane.currentContent?.childWindowTab === $0.tab } == true } }
            if let pane, pane.workspace?.isParked == false { pane.workspace?.focus.send(.contentPresented(pane: pane.paneKey)) }
            return pane != nil
        }
        DebugTimings.markLaunch("dfl.home_history")
        services.windows.layoutCache = launchReads.shell.layoutCache // the last run's layout, read before stage 0's commit
        services.windows.restoreWhenLoaded(); if services.windows.controllers.first?.window?.commitFirstFrameNow() == true { DebugTimings.markLaunch("first_window_flushed") } // CMUX-629: the frame now, not after the queued launch work
        firstFrame.whenOpen { [weak services] in services?.windows.recordSaver.launchRecord.schedule(); services?.windows.recordSaver.layoutCache.note() }
        DebugTimings.markLaunch("dfl.windows")
        // The runtime pack check wires the engine reason at once; its download waits until asked.
        services.startChromiumRuntime(); launchHold.whenReleased { [weak services] in services?.startHiddenPageSpares() } // pages nobody sees (CMUX-629)
        // Other apps' sign-ins, before any request a launch by one delivers.
        // The engines' incognito profiles and the Chromium engine's sign-in tabs (AppServices).
        let webAuthWindows = WebAuthSessionWindows(host: services, logger: services.daemon.logger,
                                                   profiles: services.browserStores.offTheRecord, signInCallbacks: services.signInCallbacks,
                                                   contextMenus: services.contextMenus, activeLook: services.activeLook)
        // The same panel opens Connect GitHub's pages over the app's window; the app finishes GitHub's return itself.
        webAuthHandler = GitHubInstallSheet.install(opener: webAuthWindows, auth: services.cloud.auth)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        // A cmux tab's return to this app (GitHub's completion, the sign-in callback): same route, no prompt, its tab closes.
        let ownLinks = BrowserExternalApps.shared, auth = services.cloud.auth
        ownLinks.openOwnURL = { [weak self] in self?.routeOpenedURL($0) }
        ownLinks.isOwnHandoff = { auth.isAppHandoff($0) }
        ownLinks.closesHandoffTab = SignInPage.startedFlow
        ownLinks.isFlowReturn = { SettingsConnections.isReturn($0) }  // Connections' return, from the tab its Connect opened
        auth.openSignInInApp = { [weak services] url in  // a flow page (cmux sign-in, Connections) in a front-window tab its return closes
            guard let services, let window = services.windows.active else { return false }
            ownLinks.noteFlowPage(url); guard services.linkOpener.openWeb(url, from: window.focusedPane, background: false) else { return false }
            services.windows.bringToFront(window); return true }
        services.windows.onContentDidAppear = { [weak services] in services?.externalOpen.flush(); services?.pageHostPool.windowDidAppear($0.window) }
        // A launch whose first window never draws (no window, a daemon that never answers) still
        // starts the work waiting for that frame.
        openedURLs.start { [weak self] in self?.routeReadyURL($0) }
        // Work the launch window does not draw: one step per main turn after the first frame (Chromium's crash-loop border and
        // the glass look too). Cloud and Home at once (the front may be Home's Chief); the rest after the front chat drew.
        let stop: @MainActor () -> Bool = { [weak services] in services?.windows.isTerminating ?? true }, mark: @MainActor @Sendable (String) -> Void = { DebugTimings.markLaunch($0) }
        firstFrame.afterOpen(stop: stop, mark: mark, ["cloud": { [weak self, weak services] in self?.cloudContext = services?.startCloud() }, "home": { [weak services] in services?.home.start() }])
        FrontChatPaintGate.make(after: firstFrame).afterOpen(stop: stop, mark: mark, [
            "harness_icons": { [weak services] in services?.harnessIcons.start() },
            "bookmarks": { [weak services] in if let services { services.bookmarks.start(directory: profilesDirectory, importStore: services.onboarding.importStore) } },
            "history": { [weak services] in services?.history.start(supportDirectory: profilesDirectory.deletingLastPathComponent()) },
            "borders_glass": { [weak services] in services?.observeBorders(); services?.observeGlass() },
            "update_feed": { [weak services] in if let services { services.updateFeedObservation = UpdateFeedPosting.follow(services) } },
            "ghostty_reload": { [weak self] in self?.ghosttyConfigLiveReload = GhosttyConfigLiveReload(); self?.ghosttyConfigLiveReload?.start() },
            "services_provider": { [weak services] in if let services { NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen) } },
            "tab_warmups": { [weak services] in services?.startLaterTabWarmups() },
        ])
        firstFrame.armBackstop(after: .seconds(3))
    }

    /// One palette warm-up step per idle moment (`PaletteController.prepare`), then `done` at the next idle moment.
    private static func preparePalette(_ palette: PaletteController?, step: Int, done: @escaping @MainActor () -> Void) {
        IdleOnce().schedule {
            guard let palette, palette.prepare(step: step) else { return IdleOnce().schedule(done) }
            preparePalette(palette, step: step + 1, done: done)
        }
    }

    /// cmux-next.json settings and the tagged control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(services: AppServices, launch: SettingsController.LaunchRead) {
        // Start the web OTA launch check before any restored or prewarmed page can
        // request its entry document. Otherwise the entry can come from the app
        // bundle while later chunks come from the kept update tree.
        WebUpdates.shared.prepare(launch.snapshot.updates, bundle: .main, cli: services.bundledCLI)
        // Before any page asks: cmux Live off ignores web-dev.json from the first request.
        WebDevOverride.setAllowed(launch.snapshot.updates.liveWebReload)
        if LaunchIdentity.ignoresCustomizations(keysHeld: NSEvent.modifierFlags.isSuperset(of: [.option, .shift])) { WebDevOverride.ignoreThisRun() }
        let registry = services.registry
        let settings = SettingsController(writer: SettingsEditSender(services.daemon.settingsFile.edit(json:file:)), registry: registry, fileURL: launch.fileURL, launch: launch, resolveThemeSlots: { [daemon = services.daemon] in await daemon.resolveThemeSlots(name: $0, text: $1) }) // the home daemon writes the file and resolves theme slots
        settings.applyManagedFeaturesNow()
        ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloud.auth).start()
        self.settings = settings
        services.settings = settings
        services.onboarding.classicFolderDefaults = .standard
        services.onboarding.importClassicSettings = { [weak services] in
            GhosttyRuntime.shared.reloadConfig()
            var failure: (any Error)?
            do { try await settings.importClassicConfig(marker: .standard) } catch { failure = error }
            do { try await settings.importClassicDefaults(marker: .standard) } catch { failure = failure ?? error }
            do { try await services?.paletteUsage.importClassicHistory() } catch { failure = failure ?? error }
            if let failure { throw failure }
        }
        UserOnlySettingConfirmation.install(settings, services: services)
        // Every palette-exposed schema setting in the palette (R93).
        let openSetting: @MainActor (String) -> Void = { [weak registry] in // Show in Settings (openSettings setting:)
            _ = registry?.perform("openSettings", invocation: ActionInvocation(arguments: ["setting": .string($0)], origin: .user))
        }
        services.palette.sources.settings = SettingsPaletteSource(settings: settings, themes: services.themes.catalog, openSetting: openSetting) { [weak services] in
            services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
        }
        services.history.startDaemonSync(settings: settings)
        services.locationTrail.watchScope(settings: settings)
        let shortcutEditor = PaletteShortcutEditor(services: services, settings: settings)
        services.paletteShortcutEditor = shortcutEditor
        services.palette.shortcutRecorder.editor = shortcutEditor
        // Managed-settings status for MDM tooling (osquery, Fleet, Jamf), plans/cmux-next/enterprise.md.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next"
        settings.writeManagedStatus(
            to: ManagedStatusReport.defaultURL(bundleID: bundleID),
            context: ManagedStatusReport.Context(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                bundleID: bundleID
            )
        )
        settings.start(announcingDiagnostics: true, rotatingFavoriteThemes: true, untilWritable: { [daemon = services.daemon] in await daemon.untilLive() }) // fresh-install Glass, theme rotation: written once the daemon is live
        firstFrame.whenOpen { [weak services] in
            guard let services else { return }
            CustomizeDoctorNotice(cli: { [bundled = services.bundledCLI] in await bundled.resolve() }, settingsFile: { [weak settings] in settings?.file.url }, untilWindow: {}, present: CustomizeDoctorNotice.toast { [weak registry] in // `customize doctor --announce` after each load; Review opens its card
                _ = registry?.perform("openSettings", invocation: ActionInvocation(arguments: ["route": .string(CustomizeDoctorNotice.route)], origin: .user)) }).follow(settings)
        }
        AppProcessRoot.shared.hangReports?.start(settings: settings, asks: services.machineAsks, isFirstLaunch: OnboardingWindowPresenter.isFirstLaunch(), firstWindow: { [firstFrame] in await firstFrame.opened() })
        AnonymousTelemetryConsent.install(on: settings) // after hang reports: `app.sendAnonymousTelemetry` writes reach the app's preference
        KeepAwakeService.shared.start(settings: settings, store: services.daemon.store, menuBar: services.menuBarExtra)
        let acpmux = QuitAgents.environment(services)
        AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        AgentPageChats.wireSandbox(services.agentTabs, services: services)
        NewTabClosed.wire(services.agentTabs, services: services)
        // Settings > Advanced > Experiments > Toasts v2 (`experiments.toastsV2`) follows into the one toast center.
        Task { [weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await on in ObservationStream({ settings.snapshot.experimentSwitches["toastsV2"] == true }) { CmuxToastCenter.shared.v2 = on }
        }
        // macOS posts no notification when an MDM profile changes; activation is the event-driven backstop next to the
        // managed-file watchers. A full-screen window an update relaunch kept back enters once the user is in cmux (`enterRestoredFullScreens`).
        Task { [weak settings, weak services] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                settings?.managedPreferencesMayHaveChanged()
                services?.windows.enterRestoredFullScreens()
                await services?.paidPlanReturned() // an upgrade's payment page sends the person back here
                await services?.joinConsent.refresh() // a consent refusal acpmux recorded meanwhile; reads nothing with Labs off
                if let services { CloudStartChat.warmSpare(services) } // intent, never awaited: the next activation runs at once
            }
        }
        services.configActions.start(settings: settings)
        services.projectActions.start()
        services.personInput.start(); services.cache.cef.personInput = { [ledger = services.personInput] in ledger.isPerson($0) }
        services.joinConsent.follow(settings: settings)
        if !environment.noActivate { services.signInEnroll.follow() } // an agent-launched build enrolls no machine
        // Agent-launched builds never take system-wide keys from the person's app, nor a menu bar item.
        if !environment.noActivate { services.globalHotKeys.start(); services.menuBarExtra.follow(settings, background: services.background) }
        services.cache.browserTabs.preference.follow(settings)
        if settings.snapshot.browserDefaultEngine == .chromium, AgentPaneTunables.chromium.value, !services.crashRecovery.recovery.isSafeRestart { services.cache.cef.initializeAfter(launchReads.chromium.initializeGate(firstFrame)); services.cache.cef.preload() } // map the framework now, off main, on every launch: a restored chat's page starts Chromium as the window builds, and a bare launch (piece 8) shows Home, whose Chief page is a Chromium page too (skipping the map there left Home's pane blank about 270 ms longer, mapping after the first frame: NIGHTLY 4557245517201, cef.step.start_called 4112 ms, map_done 4381 ms, first page pixels 5281 ms). CefInitialize still waits for the first frame unless the last quit left a page on screen (CMUX-571)
        BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, cef: services.cache.cef)
        WorkspaceAutoNameWiring(services: services).start(settings: settings) // `workspaces.autoName.variant` persist (hq#1957)
        BrowserOmnibarPreference.follow(settings, cache: services.cache)
        services.cache.localEcho.follow { [weak settings] in settings?.snapshot.terminalPredictiveLocalEcho ?? true }
        services.notifications.follow(settings)
        services.followMacScreenSettings(settings)
        services.startDeviceHub(settings)
        services.updater.follow(settings)
        services.startHibernation(settings: settings)
        services.terminalTheme.follow(settings)
        services.themes.start()
        services.themes.followChromeTheme(settings)
        services.remoteLocalhost.follow(settings)
        services.bookmarks.follow(settings)
        services.apps.start()
        Task {
            await settings.waitForLoad(atLeast: 1); await launchSettle.settled(within: .seconds(4)) // control socket: after the first frames (cx-z9kz0)
            Task { [daemon = services.daemon] in await daemon.untilLive(); await settings.runLaunchMigrations(marker: .standard) } // legacy NEXT keys and stored defaults: written by the daemon once it is live; the control socket does not wait
            do {
                try control.start(registry: registry, settings: settings, launch: environment.launch, services: services)
                control.registerCloudMethods(services)
                control.registerAccountsMethods(services)
                control.registerBillingMethods(services)
                control.registerRemoteMethods(services)
                control.service?.router.register([services.keyRequests.controlMethod]) // keys.request (Settings > Keys)
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
                control.service?.router.attach(health: services.healthFeeds.health) // debug.health, debug.health.inject
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
                                           await MainActor.run { settings?.snapshot.browserAgentMouse } ?? AgentMouseSetting.fallback
                                       }, mirrors: services).install(on: router)
                    services.apps.attach(router: router)
                }
                logger.info("control socket \(self.control.socketPath ?? "", privacy: .public)")
                services.updater.attachHealthCheck(socket: { [weak self] in self?.control.socketPath }, file: { [reporter = services.crashReporting.reporter] in reporter.captureNonFatal($0, type: $1, fingerprint: $2, tags: $3, extra: $4) })
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
        let auth = services.cloud.auth // GitHub's install redirect handed back here: the app finishes it itself (#46018)
        guard !SlackConnectedLink.handle(url, scheme: services.linkScheme, show: { try? services.settingsWindow.show(section: .accounts, route: $0) }), !services.accounts.github.finishCompletion(url, auth: auth), OpenedURLRouting(isAuthCallback: { auth.isCallback($0) }, open: { services.externalOpen.open($0) }).route(url) == .auth else { return }
        Task { if await auth.callbackFailed(url) { try? services.settingsWindow.show(section: .accounts) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cloudBootstrap?.cancel()
        cloudBootstrap = nil
        services?.crashRecovery.applicationWillTerminate()
        services?.windows.recordSaver.layoutCache.flushNow() // what the quit's awaited flushes missed: one write, on this thread
        services?.crashReporting.reporter.stallSummary.close()  // the open hour's stall counts
        // The release push's socket closes and nothing reconnects (ReleasePushListener).
        services?.updater.stopReleasePush()
        services?.agentTabs.pageChats.stopNotices()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
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
        services?.projectActions.stop()
        services?.globalHotKeys.stop()
        settings?.stop()
        services?.iphone.stop()
        services?.dockMenu.stop()
        services?.daemon.shutdownConnection()
    }

    /// The Dock icon's menu, from rows the controller already holds: it never waits on acpmux or disk.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { services?.dockMenu.menu() }

    /// The app stays running with no windows (standard macOS behavior): a window closes when its
    /// last workspace closes, and the daemon keeps every terminal regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Dock click or an open of the running app (a launcher, Finder, `open -a`, a second launch), with or without a window
    /// on screen (`reopenOrCreateWindow`): a window it has comes forward; only with none does one come back or open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        services?.input.endRelaunchBehind("dock click", activating: true) // in an update relaunch's startup: the user chose cmux
        // Under CMUX_NEXT_NO_ACTIVATE=1 too the user chose cmux, so its activation is not handed back (https://github.com/manaflow-ai/cmux/issues/34575).
        services?.input.noteReopenRequested()
        services?.windows.reopenOrCreateWindow()
        return false
    }
}

extension AppDelegate {
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
            await services.windows.recordSaver.launchRecord.flush()
            await services.windows.recordSaver.layoutCache.flush()
            await files
        }, armDeadline: armDeadline, deadlineEnd: services()?.quitDeadlineEnd(), end: end)
    }
}
