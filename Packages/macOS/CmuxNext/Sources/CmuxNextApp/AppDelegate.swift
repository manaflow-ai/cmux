import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.current()
    private var services: AppServices!
    private var settings: SettingsController?
    private var control: ControlService?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = AppServices(environment: environment)
        self.services = services
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        startSettingsAndControl(registry: services.registry)
        NSApp.mainMenu = MainMenu.make(registry: services.registry)
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        if !environment.noActivate { NSApp.activate() }
        services.daemon.start()
        services.windows.restoreWhenLoaded()
    }

    /// cmux.json settings (density, shortcut overrides) and the tagged
    /// control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(registry: ActionRegistry) {
        let settings = SettingsController(registry: registry)
        self.settings = settings
        services.settings = settings
        settings.start()
        Task {
            await settings.waitForLoad(atLeast: 1)
            do {
                control = try ControlService.start(registry: registry, settings: settings)
                logger.info("control socket \(self.control?.socketPath ?? "", privacy: .public)")
            } catch {
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        Task {
            await services.windows.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        settings?.stop()
        services?.daemon.shutdownConnection()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
