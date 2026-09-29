import AppKit
import CmuxNextActions
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.current()
    private var services: AppServices!
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = AppServices(environment: environment)
        self.services = services
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        NSApp.mainMenu = MainMenu.make(registry: services.registry)
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        if !environment.noActivate { NSApp.activate() }
        services.daemon.start()
        services.windows.restoreWhenLoaded()
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
        services?.daemon.shutdownConnection()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
