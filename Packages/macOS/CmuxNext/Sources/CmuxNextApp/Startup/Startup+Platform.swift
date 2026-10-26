import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPopups
import CmuxNextSettings

// Launch calls for the system integrations: text input, window placement, the CLI pointer, the platform
// services, other apps' sign-ins and opened URLs (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// The native caret, the window placement rule, relaunch at login and the `cmux` CLI pointer.
    func registerPlatformLaunch() {
        // No system caret bubble over cmux's own native text fields (before any field edits).
        NativeCaretAccessory.install()
        // Every window, shell or auxiliary, opens by one placement rule.
        WindowPlacement.noActivate = environment.noActivate
        WindowPlacement.testScreen = environment.testWindow?.screen
        // An agent or bench launch must never come back by itself: without this, loginwindow reopens it at
        // the next login (without the agent's environment, so it activates and takes the tag's socket).
        if environment.isolatedLaunch { NSApp.disableRelaunchOnLogin() }
        // A `cmux` shim outside this app runs the CLI of the app opened last
        // (plans/cmux-next/version-skew.md); an isolated launch never claims it.
        if LastAppCLIPointer.shouldPublish(environment: ProcessInfo.processInfo.environment),
           let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux").path {
            Task.detached(priority: .utility) { LastAppCLIPointer().publish(cliPath: cli) }
        }
    }

    /// The platform services and Energy Saver, following settings.
    func registerPlatformServices(services: AppServices, settings: SettingsController) {
        // The platform services: what the first frame or the restore reads now, the rest posted (p08-startup-029).
        services.startPlatformServices(settings: settings, on: order.startup, hotKeys: !environment.isolatedLaunch)
        services.followEnergySaver(settings)
    }

    /// Other apps' sign-ins, URL Apple events, the Services menu and the opens held before the services existed.
    func registerExternalOpen(services: AppServices) {
        // Other apps' sign-ins, before any request a launch by one delivers.
        // The engines' incognito profiles and the Chromium engine's sign-in tabs (AppServices).
        let webAuthWindows = WebAuthSessionWindows(host: services, logger: services.daemon.logger,
                                                   profiles: services.browserStores.offTheRecord, signInCallbacks: services.signInCallbacks,
                                                   contextMenus: services.contextMenus, mainWork: services.mainWork)
        let webAuthHandler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: webAuthWindows))
        self.webAuthHandler = webAuthHandler
        WebAuthSessionHandler.install(webAuthHandler)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] in services?.externalOpen.flush(); services?.pageHostPool.windowDidAppear($0.window) }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
        launchOpens.release { item in  // services exist now: nothing is held while this runs
            switch item {
            case .url(let url): routeOpenedURL(url)
            case .activity(let type, let webpageURL): _ = services.externalOpen.continueActivity(type: type, webpageURL: webpageURL)
            }
        }
    }
}
