import AppKit
import CmuxNextActions
import CmuxNextDaemon
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.current()
    private let registry = ActionRegistry()
    private let model = ShellModel()
    private var windowController: MainWindowController?
    private var daemonEventsTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActions.register(in: registry, model: model)
        NSApp.mainMenu = MainMenu.make(registry: registry)

        let controller = MainWindowController(model: model, registry: registry, environment: environment)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()

        startDaemon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemonEventsTask?.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Consumes control events from the placeholder daemon connection. The
    /// daemon agent replaces the transport; this loop becomes the place where
    /// events are applied to stores.
    private func startDaemon() {
        let daemon = DaemonConnection(endpoint: DaemonEndpoint(socketPath: environment.socketPath ?? ""))
        let logger = logger
        daemonEventsTask = Task {
            for await event in await daemon.events() {
                logger.info("daemon event: \(String(describing: event), privacy: .public)")
            }
        }
    }
}
