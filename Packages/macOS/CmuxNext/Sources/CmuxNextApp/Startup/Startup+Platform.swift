import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextKeepAwake
import CmuxNextPopups
import CmuxNextSettings

// Launch calls for the system integrations: text input, window placement, the CLI pointer, keep-awake,
// mobile, devices, the updater, Computer Use, hot keys, window chrome and opened URLs (task 014,
// see Startup+Core.swift).
extension AppDelegate {
    /// The native caret, the window placement rule, relaunch at login and the `cmux` CLI pointer.
    func registerPlatformLaunch() {
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
    }

    /// Keep-awake, Energy Saver and the mobile pairing, following settings.
    func registerKeepAwakeAndMobile(services: AppServices, settings: SettingsController) {
        KeepAwakeService.shared.start(settings: settings, store: services.daemon.store)
        services.followEnergySaver(settings)
        services.mobile.follow(settings, launch: services.environment.launch)
    }

    /// Config actions and the global hot keys.
    func registerConfigActionsAndHotKeys(services: AppServices, settings: SettingsController) {
        services.configActions.start(settings: settings)
        // Agent-launched builds never take system-wide keys from the person's app.
        if !environment.noActivate { services.globalHotKeys.start() }
    }

    /// Notifications, Share This Mac, the device hub, the updater, Computer Use and hibernation, following settings.
    func registerSystemFollows(services: AppServices, settings: SettingsController) {
        services.notifications.follow(settings)
        services.followMacScreenSettings(settings)
        services.startDeviceHub(settings)
        services.updater.follow(settings)
        ComputerUseHelperDaemon.shared.follow(settings, disabledByPolicy: { [weak services] in
            services?.registry.disabledFeatures.contains(.computerUse) ?? true
        })
        services.startHibernation(settings: settings)
    }

    /// Window borders and glass, and the update feed.
    func registerWindowChrome(services: AppServices) {
        services.observeBorders()
        services.observeGlass()
        services.updateFeedObservation = UpdateFeedPosting.follow(services)
    }

    /// Other apps' sign-ins, URL Apple events and the Services menu, before any request a launch by one delivers.
    func registerExternalOpen(services: AppServices) {
        // The engines' incognito profiles and the Chromium engine's sign-in tabs (AppServices).
        let webAuthWindows = WebAuthSessionWindows(host: services, logger: services.daemon.logger,
                                                   profiles: services.browserStores.offTheRecord, signInCallbacks: services.signInCallbacks,
                                                   contextMenus: services.contextMenus)
        let webAuthHandler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: webAuthWindows))
        self.webAuthHandler = webAuthHandler
        WebAuthSessionHandler.install(webAuthHandler)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] in services?.externalOpen.flush(); services?.pageHostPool.windowDidAppear($0.window) }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
    }
}
