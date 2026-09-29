import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTerminal
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.current()
    private let registry = ActionRegistry()
    private let model = ShellModel()
    private var windowController: MainWindowController?
    private var daemonEventsTask: Task<Void, Never>?
    private let daemonStore = DaemonStore()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActions.register(in: registry, model: model)
        NSApp.mainMenu = MainMenu.make(registry: registry)

        let controller = MainWindowController(model: model, registry: registry, environment: environment)
        windowController = controller
        controller.showWindow(nil)
        if ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] != "1" {
            NSApp.activate()
        }

        startDaemon()
        showDebugTerminalIfRequested()
        showDebugBrowserIfRequested()
    }

    /// Temporary dev hook until the App maps daemon browser tabs into panes:
    /// `CMUX_NEXT_DEBUG_BROWSER=cef|webkit` opens a browser window
    /// (BrowserDebugWindow documents the other variables).
    private func showDebugBrowserIfRequested() {
        #if DEBUG
        if let failure = BrowserDebugWindow.showIfRequested() {
            logger.error("debug browser failed: \(failure, privacy: .public)")
        }
        #endif
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

    /// Ensures the bundled cmux-tui daemon, connects, and mirrors its tree
    /// into `daemonStore`. Mapping the store into the shell's view models is
    /// the App layer's next step.
    private func startDaemon() {
        let logger = logger
        let store = daemonStore
        daemonEventsTask = Task {
            do {
                let launcher = try DaemonLauncher.forApp()
                let connection = DaemonConnection(endpointProvider: launcher.endpointProvider)
                try await connection.start()
                await store.run(connection: connection)
            } catch {
                logger.error("cmux-tui daemon unavailable: \(String(describing: error), privacy: .public)")
                store.markFailed(String(describing: error))
            }
        }
    }
}
