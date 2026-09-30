import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDesign
import CmuxNextPalette
import CmuxNextSettings
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment = {
        var environment = AppEnvironment.current()
        environment.marksRun = true
        return environment
    }()
    private var services: AppServices!
    private var settings: SettingsController?
    private let control = AppControl()
    private var cloudContext: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        control.startWatchdog()
        DebugTimings.markLaunch("did_finish_launching_start")
        DebugTimings.install()
        defer { DebugTimings.markLaunch("did_finish_launching_end") }
        // Every window, shell or auxiliary, opens by one placement rule.
        WindowPlacement.noActivate = environment.noActivate
        WindowPlacement.testScreen = environment.testWindow?.screen
        // Chrome colors derive from the Ghostty theme; load it before any window.
        ThemeBridge.start()
        DebugTimings.markLaunch("dfl.theme")
        let services = AppServices(environment: environment)
        self.services = services
        DebugTimings.markLaunch("dfl.services")
        AppActions.bind(services)
        HandlerCoverage.verify(services.registry)
        services.palette.bindRegistryActions()
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(registry: services.registry)
        DebugTimings.markLaunch("dfl.settings")
        NSApp.mainMenu = MainMenu.make(registry: services.registry)
        DebugTimings.markLaunch("dfl.menu")
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        if !environment.noActivate { NSApp.activate() }
        services.daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment)
        cloudContext = services.startCloud()
        services.updater.start()
        // Before the first window opens (restoreWhenLoaded opens one at once).
        services.windows.onPresent = { [weak services] controller in
            services?.crashRecovery.showRestartNotice(on: controller.window)
        }
        DebugTimings.markLaunch("dfl.daemon_cloud_updater")
        services.windows.onFirstWindow = { [palette = services.palette] _ in
            // Once the first window's frame is committed, the palette panel
            // is made at the next idle moment, so the first open costs what
            // later opens cost (Spotlight and Chrome's omnibox open in one frame).
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    DebugTimings.markLaunch("first_window_frame_committed")
                    Self.preparePalette(palette, step: 0)
                }
            }
        }
        services.palette.onPresented = { DebugTimings.palettePresented($0) }
        services.windows.restoreWhenLoaded()
        DebugTimings.markLaunch("dfl.windows")
        // After two quick unexpected ends in a row, Chromium starts only
        // when the user reloads a browser tab.
        if !services.crashRecovery.recovery.skipsBrowserPages { services.startChromiumWarmup() }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// One palette warm-up step per idle moment (`PaletteController.prepare`).
    private static func preparePalette(_ palette: PaletteController?, step: Int) {
        IdleOnce.schedule {
            guard let palette, palette.prepare(step: step) else { return }
            preparePalette(palette, step: step + 1)
        }
    }

    /// cmux.json settings (density, shortcut overrides) and the tagged
    /// control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(registry: ActionRegistry) {
        let settings = SettingsController(registry: registry)
        self.settings = settings
        services.settings = settings
        settings.start()
        services.tabBarButtons.start(settings: settings)
        services.cache.browserTabs.preference.follow(settings)
        Task {
            await settings.waitForLoad(atLeast: 1)
            do {
                try control.start(registry: registry, settings: settings, launch: environment.launch, services: services)
                control.registerCloudMethods(services)
                control.registerMobileMethods(services)
                control.registerUpdateMethods(services.updater)
                control.registerInputMethods(services)
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
        let compat = CompatService(frontend: frontend, terminalEnvironment: environment.terminalEnvironment) {
            frontend.currentConnection()
        }
        compat.install(on: router)
        // Hook statuses (`set_status`, `set_progress`) show in sidebar rows.
        let board = services.statusBoard
        compat.observeSidebarStatus { [weak compat] uuid in
            let line = compat?.sidebarStatusLine(workspace: uuid)
            Task { @MainActor in board.set(line, workspace: uuid) }
        }
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
        services?.crashRecovery.applicationWillTerminate()
        cloudContext?.cancel()
        services?.cloud.stop()
        for session in services?.machines.cloud ?? [] { session.disconnect() }
        control.stop()
        services?.tabBarButtons.stop()
        settings?.stop()
        services?.mobile.stop()
        services?.daemon.shutdownConnection()
    }

    /// The app stays running with no windows (standard macOS behavior): a
    /// window closes when its last workspace closes, and the daemon keeps
    /// every terminal regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click with no window open: the last closed window comes back
    /// with its workspaces, else a new window with a new workspace.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let windows = services?.windows else { return true }
        windows.reopenOrCreateWindow()
        return false
    }
}
