import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextPages
import CmuxNextPopups
import CmuxNextTerminal
import CmuxNextWakeups

// Launch calls for the process and the system integrations: the quit signals and the watchdog, text
// input, window placement, the CLI pointer, Ghostty's keybinds and config, the browser's data and
// first-party schemes, other apps' sign-ins and opened URLs (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// The quit signals and the main-thread watchdog.
    func registerProcess() {
        // SIGTERM, SIGINT and SIGHUP (dev tooling, `kill`, Ctrl-C) are
        // "Quit, keep sessions" with no alert.
        QuitSignal.install(quit: { [weak self] in
            guard let services = self?.services else { return NSApp.terminate(nil) }
            services.quit.terminateFromSignal()
        }, forceExit: { [weak self] in
            self?.forcedQuitExit.start()
        })
        control.attachWatchdog()
        (NSApp as? CmuxApplication)?.inputQueueing = control.watchdog
    }

    /// The native caret, the window placement rule, relaunch at login, design mode's leftovers and the `cmux` CLI pointer.
    func registerPlatformLaunch() {
        // No system caret bubble over cmux's own native text fields (before any field edits).
        NativeCaretAccessory.install()
        // Every window, shell or auxiliary, opens by one placement rule.
        WindowPlacement.noActivate = environment.noActivate
        WindowPlacement.testScreen = environment.testWindow?.screen
        // An agent or bench launch must never come back by itself: without this, loginwindow reopens it at
        // the next login (without the agent's environment, so it activates and takes the tag's socket).
        if environment.isolatedLaunch { NSApp.disableRelaunchOnLogin() }
        // Design mode files earlier launches left (a fenced files-lane post), and the CLI pointer a `cmux`
        // shim outside this app runs, written now (plans/cmux-next/version-skew.md; an isolated launch never claims it).
        var publishCLIPointer: (@Sendable () -> Void)?
        if LastAppCLIPointer.shouldPublish(environment: ProcessInfo.processInfo.environment),
           let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux").path {
            publishCLIPointer = { _ = LastAppCLIPointer().publish(cliPath: cli) }
        }
        LaunchFileJobs(removeDesignModeTempFiles: { BrowserDesignModeController.tempFiles.removeEarlierLaunches() },
                       publishCLIPointer: publishCLIPointer).post(on: launchReads.work)
    }

    /// The binding table's Ghostty keybinds, the live config reload, app-scoped Ghostty actions, the input-source keys and the runtime's frame hooks.
    func registerTerminal(services: AppServices) {
        let ghosttyKeybinds = GhosttyKeybindSync(router: services.keyRouter, launchImages: launchImageHold)
        self.ghosttyKeybinds = ghosttyKeybinds
        ghosttyKeybinds.start()
        let ghosttyConfigLiveReload = GhosttyConfigLiveReload(deadlines: services.mainDeadlines)
        self.ghosttyConfigLiveReload = ghosttyConfigLiveReload
        ghosttyConfigLiveReload.startAfterStartup(on: order.startup)
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface. Inline before the restore: a
        // pane can mount before the first frame, and its key-equivalent path reads these hooks on every key.
        TerminalHooks(services: services).install()
        // The terminal key path's input-source switch keys, read off main now and on each activation.
        GhosttyRuntime.shared.inputSources.start(runner: services.work)
        GhosttyRuntime.shared.traceHook.connect(on: services.mainWork, presents: FrameScheduler.appDisplays.presents)
        // Renderer-presented terminal frames pass through no `setContents:` hook: they count in the app's RenderStats.
        GhosttyRuntime.shared.traceHook.countPresentedFrames(in: control.renderStats.presentedFrames)
        GhosttyRuntime.shared.attach(to: services.mainWork, holdsHiddenActions: services.features.isEnabled(.terminalHiddenActionHold))
    }

    /// Bookmarks, history, the first-party page schemes and the page host's statics.
    func registerBrowserData(services: AppServices, profilesDirectory: URL) {
        services.bookmarks.start(directory: profilesDirectory, importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: profilesDirectory.deletingLastPathComponent())
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install(processGroups: services.features.isEnabled(.pageProcessGroups), rendererSharing: services.features.isEnabled(.cmuxPageRendererSharing))
        // The shared chunks into memory on the files lane, so WebKit page views get them in one turn.
        WebBundleOverlay.shared.readBundledShared(on: services.work)
        services.configureChromiumSpares()
        services.cache.cef.setAdBlockerAtFirstTab(services.features.isEnabled(.chromiumAdBlockerAtFirstTab))
        // The page host already exists (`services.iconPicker` above reads it) but has opened no page;
        // the statics forward to it for page views not yet made through `webUI.open`
        // (p13-webui-006 to 009 move them, 010 deletes the statics).
        PageWebView.openPanel = services.webUI.openPanel
        PageWebView.chromiumHosting = services.webUI.chromium
    }

    /// Other apps' sign-ins, URL Apple events, the Services menu and the opens held before the services existed.
    func registerExternalOpen(services: AppServices) {
        // Other apps' sign-ins, before any request a launch by one delivers.
        // The engines' incognito profiles and the Chromium engine's sign-in tabs (AppServices).
        let webAuthWindows = WebAuthSessionWindows(host: services, logger: services.daemon.logger,
                                                   profiles: services.browserStores.offTheRecord, signInCallbacks: services.signInCallbacks,
                                                   contextMenus: services.contextMenus, mainWork: services.mainWork, inputTap: services.inputTap)
        let webAuthHandler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: webAuthWindows))
        self.webAuthHandler = webAuthHandler
        WebAuthSessionHandler.install(webAuthHandler)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] _ in services?.externalOpen.flush(); AppProcessRoot.shared.hangReports?.memory?.workspaceDidShow() }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
        launchOpens.release { item in  // services exist now: nothing is held while this runs
            switch item {
            case .url(let url): routeOpenedURL(url)
            case .activity(let type, let webpageURL): _ = services.externalOpen.continueActivity(type: type, webpageURL: webpageURL)
            }
        }
    }
}
