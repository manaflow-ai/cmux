import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTerminal
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
        showDebugTerminalIfRequested()
    }

    /// Temporary dev hook until the App maps daemon terminals into panes:
    /// `CMUX_NEXT_DEBUG_TERMINAL=1` opens a Ghostty surface on a local shell.
    private func showDebugTerminalIfRequested() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_NEXT_DEBUG_TERMINAL"] == "1" else { return }
        TerminalDebugWindow.showLocalShell(initialInput: environment["CMUX_NEXT_DEBUG_TERMINAL_INPUT"])
        TerminalDebugWindow.showScriptedFollower()
        #endif
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
