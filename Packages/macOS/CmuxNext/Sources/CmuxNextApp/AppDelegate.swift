import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.current()
    private var services: AppServices!
    private var settings: SettingsController?
    private let control = AppControl()
    private var cloudContext: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        control.startWatchdog()
        let services = AppServices(environment: environment)
        self.services = services
        AppActions.bind(services)
        HandlerCoverage.verify(services.registry)
        services.palette.bindRegistryActions()
        startSettingsAndControl(registry: services.registry)
        NSApp.mainMenu = MainMenu.make(registry: services.registry)
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        if !environment.noActivate { NSApp.activate() }
        services.daemon.start(launch: environment.launch)
        cloudContext = services.startCloud()
        services.windows.restoreWhenLoaded()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// cmux.json settings (density, shortcut overrides) and the tagged
    /// control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(registry: ActionRegistry) {
        let settings = SettingsController(registry: registry)
        self.settings = settings
        services.settings = settings
        settings.start()
        services.tabBarButtons.start(settings: settings)
        Task {
            await settings.waitForLoad(atLeast: 1)
            do {
                try control.start(registry: registry, settings: settings, launch: environment.launch, services: services)
                control.registerCloudMethods(services)
                if let router = control.service?.router { installCompat(on: router) }
                logger.info("control socket \(self.control.socketPath ?? "", privacy: .public)")
            } catch {
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The old `cmux` CLI's v2/v1 verbs (plans/cmux-next/cli-compat.md).
    private func installCompat(on router: ControlRouter) {
        let frontend = services.compat!
        frontend.afterIntent = { [control] in control.publishSnapshotNow() }
        let compat = CompatService(frontend: frontend, terminalEnvironment: environment.launch.terminalEnvironment) {
            frontend.currentConnection()
        }
        compat.install(on: router)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        // Quit (menu, Cmd-Q, socket) never waits on an open sheet.
        SheetDismissal.endAll()
        Task {
            await services.windows.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `<scheme>://auth-callback` from the browser fallback of sign-in.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        let cloud = services?.cloud
        Task { _ = await cloud?.auth.handleCallback(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cloudContext?.cancel()
        services?.cloud.stop()
        for session in services?.machines.cloud ?? [] { session.disconnect() }
        control.stop()
        services?.tabBarButtons.stop()
        settings?.stop()
        services?.mobile.stop()
        services?.daemon.shutdownConnection()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
