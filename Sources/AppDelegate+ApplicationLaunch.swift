import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Application open, reopen, and didFinishLaunching
extension AppDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if handleCmuxExternalURLs(from: urls) {
            return
        }

        // Before the auth graph is configured, fall back to a default router
        // (built-in cmux schemes) so dropped callbacks are still detected.
        let callbackRouter = auth?.callbackRouter ?? AuthCallbackRouter()
        let authCallbacks = urls.filter(callbackRouter.isAuthCallbackURL)
        if let browserSignIn = auth?.browserSignIn {
            for url in authCallbacks {
                Task { @MainActor in
                    let signedIn = await browserSignIn.handleCallbackURL(url)
                    if !signedIn {
                        AuthDebugLog().log("auth.callback did not complete sign-in")
                    }
                }
            }
        } else if !authCallbacks.isEmpty {
            AuthDebugLog().log("auth.callback dropped: auth graph not configured yet")
        }

        let externalFileURLs = externalOpenFileURLs(from: urls)
        let terminalFileRequests = TerminalDefaultFileOpenRequest.requests(from: externalFileURLs)
        let terminalFilePaths = Set(terminalFileRequests.map { $0.fileURL.path(percentEncoded: false) })
        let fileURLs = externalFileURLs.filter { url in
            !terminalFilePaths.contains(url.standardizedFileURL.path(percentEncoded: false))
        }
        let directories = externalOpenDirectories(from: urls.filter { externalOpenURLIsDirectory($0) })
        guard !terminalFileRequests.isEmpty || !fileURLs.isEmpty || !directories.isEmpty else { return }

        prepareForExplicitOpenIntentAtStartup()
        for request in terminalFileRequests {
            openTerminalDefaultFileRequest(
                request,
                debugSource: "application.openURLs.defaultTerminal"
            )
        }
        for fileURL in fileURLs {
            _ = openFilePreviewInPreferredMainWindow(
                filePath: fileURL.path(percentEncoded: false),
                debugSource: "application.openURLs"
            )
        }
        for directory in directories {
            openWorkspaceForExternalDirectory(
                workingDirectory: directory,
                debugSource: "application.openURLs"
            )
        }
    }

    private func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if hasVisibleMainTerminalWindow() {
            _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)
            return true
        }
        if mainWindowVisibilityController.showApplicationWindows(
            windows: mainWindowsForVisibilityController(),
            reason: .applicationReopen,
            activation: .none
        ) == nil {
            _ = ensureInitialMainWindowIfNeeded()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = isRunningUnderXCTest(env)
        let telemetryEnabled = TelemetrySettings.enabledForCurrentLaunch
        StartupBreadcrumbLog.append(
            "appDelegate.didFinish.begin",
            fields: [
                "xctest": isRunningUnderXCTest ? "1" : "0",
                "telemetry": telemetryEnabled ? "1" : "0"
            ]
        )
        AppIconLaunchState.markDidFinishLaunching()
        AppearanceSettingsUserDefaultsObserver.shared.startObserving()
        if isRunningUnderXCTest {
            NSApp.setActivationPolicy(.regular)
        } else {
            syncActivationPolicy()
        }
        StartupBreadcrumbLog.append("appDelegate.didFinish.activationPolicy.synced")

        // Prewarm the shared restorable-agent index off the main thread so the first
        // tab/workspace/window close after launch reads a warm cache instead of paying a
        // synchronous RestorableAgentSessionIndex.load() on the main thread. See
        // closedPanelHistoryEntry.
        if !isRunningUnderXCTest {
            SharedLiveAgentIndex.shared.scheduleRefreshIfStale()
        }

        claimAuthCallbackURLSchemes()
        StartupBreadcrumbLog.append("appDelegate.didFinish.authSchemes.claimed")

        // Install the Feed (workstream) store. Separate from the transport
        // wiring: the store is a plain singleton here, and the socket
        // `feed.*` V2 verbs in `TerminalController` push into it directly
        // via `FeedCoordinator`.
        FeedCoordinator.shared.install(
            store: WorkstreamStore(
                transport: NullWorkstreamTransport(),
                persistence: WorkstreamPersistence(fileURL: WorkstreamPersistence.defaultFileURL())
            )
        )
        StartupBreadcrumbLog.append("appDelegate.didFinish.feedStore.installed")
        Task { @MainActor in
            await FeedCoordinator.shared.store?.start()
#if DEBUG
            setupFeedSidebarUITestIfNeeded()
#endif
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemesReloadNotification(_:)),
            name: CmuxThemeNotifications.reloadConfig,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReactGrabDidCopySelection(_:)),
            name: .reactGrabDidCopySelection,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFeedRequestFocus(_:)),
            name: .feedRequestFocus,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFeedRequestSendText(_:)),
            name: .feedRequestSendText,
            object: nil
        )

#if DEBUG
        // UI tests run on a shared VM user profile, so persisted shortcuts can drift and make
        // key-equivalent routing flaky. Force defaults for deterministic tests.
        if isRunningUnderXCTest {
            SystemWideHotkeySettings.reset()
            KeyboardShortcutSettings.resetAll()
        }
#endif

#if DEBUG
        writeUITestDiagnosticsIfNeeded(stage: "didFinishLaunching")
        CmuxMainRunLoopStallMonitor.shared.installIfNeeded()
        CmuxMainThreadTurnProfiler.shared.installIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeUITestDiagnosticsIfNeeded(stage: "after1s")
        }
#endif

        if telemetryEnabled {
            // Pre-warm locale before Sentry to avoid a startup data race.
            // Locale initialization (os.locale.ensureLocale / NSLocale._preferredLanguages)
            // on the main thread can race with Sentry's background init thread
            // calling posix.getenv, causing a SIGSEGV ~134ms after launch.
            // Forcing locale access here before SentrySDK.start eliminates the race.
            // Related to: #836
            _ = Locale.current
            _ = NSLocale.preferredLanguages

            StartupBreadcrumbLog.append("appDelegate.didFinish.sentry.begin")
            SentrySDK.start { options in
                options.dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
                #if DEBUG
                options.environment = "development"
                options.debug = true
                #else
                options.environment = "production"
                options.debug = false
                #endif
                options.sendDefaultPii = false

                // Performance tracing is disabled. The auto-instrumented root
                // `SentryTransaction.trace` serializes its `data` / `tags` /
                // `description` into the payload *after* `beforeSend` runs, and
                // the root tracer is not reachable through the public Sentry API,
                // so those fields cannot be scrubbed. Disabling transactions
                // removes that un-scrubbable egress path while keeping crash,
                // error, and app-hang reporting (which are independent of the
                // trace sample rate). cmux does not consume these performance
                // traces today.
                options.tracesSampleRate = 0.0
                // Keep app-hang tracking enabled, but avoid reporting short main-thread stalls
                // as hangs in normal user interaction flows.
                options.appHangTimeoutInterval = 8.0
                // Attach stack traces to all events
                options.attachStacktrace = true
                // Avoid recursively capturing failed requests from Sentry's own ingestion endpoint.
                options.enableCaptureFailedRequests = false
                // Redact file paths, emails, and secrets from every outgoing
                // event, breadcrumb, and (belt-and-suspenders, if tracing is ever
                // re-enabled) child performance span before it leaves the device.
                let scrubber = SentryEventScrubber()
                options.beforeSend = { event in scrubber.scrub(event) }
                options.beforeBreadcrumb = { breadcrumb in scrubber.scrub(breadcrumb) }
                options.beforeSendSpan = { span in scrubber.scrub(span) }
            }
            StartupBreadcrumbLog.append("appDelegate.didFinish.sentry.complete")
        }

        if telemetryEnabled && !isRunningUnderXCTest {
            StartupBreadcrumbLog.append("appDelegate.didFinish.posthog.begin")
            PostHogAnalytics.shared.startIfNeeded()
            StartupBreadcrumbLog.append("appDelegate.didFinish.posthog.complete")
        }

        let forceDuplicateLaunchObserver = env["CMUX_UI_TEST_ENABLE_DUPLICATE_LAUNCH_OBSERVER"] == "1"

        // UI tests frequently time out waiting for the main window if we do heavyweight
        // LaunchServices registration / single-instance enforcement synchronously at startup.
        // Skip these during XCTest (the app-under-test) so the window can appear quickly.
        if !isRunningUnderXCTest {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                StartupBreadcrumbLog.append("appDelegate.singleInstance.async.begin")
                self.scheduleLaunchServicesBundleRegistration()
                StartupBreadcrumbLog.append("appDelegate.singleInstance.launchServices.scheduled")
                self.enforceSingleInstance()
                self.observeDuplicateLaunches()
                StartupBreadcrumbLog.append("appDelegate.singleInstance.async.complete")
            }
        } else if forceDuplicateLaunchObserver {
            // Some UI regressions specifically exercise launch-observer behavior while still
            // running under XCTest. Allow an explicit opt-in for those cases only.
            DispatchQueue.main.async { [weak self] in
                self?.observeDuplicateLaunches()
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        if !isRunningUnderXCTest {
            ensureApplicationIcon()
        }
        if !isRunningUnderXCTest {
            configureUserNotifications()
            installMenuBarVisibilityObserver()
            syncApplicationPresentationPreferences()
            updateController.actionDelegate = self
            updateController.startUpdaterIfNeeded()
        }
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        if !isRunningUnderXCTest {
            GlobalSearchCoordinator.shared.start()
        }
        SystemWideHotkeyController.shared.start()
        AgentHibernationController.shared.start()
        NSApp.servicesProvider = self

        StartupBreadcrumbLog.append("appDelegate.didFinish.bootstrap.begin")
        scheduleInitialMainWindowBootstrap(debugSource: "didFinishLaunching")
        StartupBreadcrumbLog.append("appDelegate.didFinish.complete")
#if DEBUG
        UpdateTestSupport(model: updateController.model, log: updateLog).applyIfNeeded()
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let trigger = env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? "<nil>"
            let feed = env["CMUX_UI_TEST_FEED_URL"] ?? "<nil>"
            updateLog.append("ui test env: trigger=\(trigger) feed=\(feed)")
        }
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
            updateLog.append("ui test trigger update check detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                updateLog.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
                if UpdateTestSupport(model: self.updateController.model, log: updateLog).performMockFeedCheckIfNeeded() {
                    return
                }
                self.checkForUpdates(nil)
            }
        }

        // In UI tests, `WindowGroup` occasionally fails to materialize a window quickly on the VM.
        // If there are no windows shortly after launch, force-create one so XCUITest can proceed.
        if isRunningUnderXCTest {
            if let rawVariant = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_VARIANT"] {
                UserDefaults.standard.set(
                    BrowserImportHintSettings.variant(for: rawVariant).rawValue,
                    forKey: BrowserImportHintSettings.variantKey
                )
            }
            if let rawShow = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_SHOW"] {
                UserDefaults.standard.set(
                    rawShow == "1",
                    forKey: BrowserImportHintSettings.showOnBlankTabsKey
                )
            }
            if let rawDismissed = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_DISMISSED"] {
                UserDefaults.standard.set(
                    rawDismissed == "1",
                    forKey: BrowserImportHintSettings.dismissedKey
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if NSApp.windows.isEmpty {
                    self.openNewMainWindow(nil)
                }
                self.moveUITestWindowToTargetDisplayIfNeeded()
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                // On headless CI runners, activate() silently fails (no GUI session).
                // Force windows visible so the terminal surface starts rendering.
                for window in NSApp.windows {
                    window.orderFrontRegardless()
                }
                self.writeUITestDiagnosticsIfNeeded(stage: "afterForceWindow")
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_BLANK_BROWSER"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self else { return }
                    _ = self.openBrowserAndFocusAddressBar(insertAtEnd: true)
                }
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_SETTINGS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    self?.openPreferencesWindow(
                        debugSource: "uiTest.browserImportHint",
                        navigationTarget: .browser
                    )
                }
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_AUTO_OPEN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    BrowserDataImportCoordinator.shared.presentImportDialog()
                }
            }
        }
#endif
    }

#if DEBUG
    func writeUITestDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = loadUITestDiagnostics(at: path)
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

        let windows = NSApp.windows
        let ids = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
        let vis = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")
        let screenIDs = windows.map { $0.screen?.cmuxDisplayID.map(String.init) ?? "" }.joined(separator: ",")
        let targetDisplayID = env["CMUX_UI_TEST_TARGET_DISPLAY_ID"] ?? ""

        payload["stage"] = stage
        payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        payload["isRunningUnderXCTest"] = isRunningUnderXCTest ? "1" : "0"
        payload["windowsCount"] = String(windows.count)
        payload["windowIdentifiers"] = ids
        payload["windowVisibleFlags"] = vis
        payload["windowScreenDisplayIDs"] = screenIDs
        payload["uiTestTargetDisplayID"] = targetDisplayID
        if let rawDisplayID = UInt32(targetDisplayID) {
            let screenPresent = NSScreen.screens.contains(where: { $0.cmuxDisplayID == rawDisplayID })
            let movedWindow = windows.contains(where: { $0.screen?.cmuxDisplayID == rawDisplayID })
            payload["targetDisplayPresent"] = screenPresent ? "1" : "0"
            payload["targetDisplayMoveSucceeded"] = movedWindow ? "1" : "0"
        }
        appendUITestRenderDiagnosticsIfNeeded(&payload, environment: env)
        appendUITestSocketDiagnosticsIfNeeded(&payload, environment: env)
        appendUITestPortalDiagnosticsIfNeeded(&payload, environment: env)

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadUITestDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func appendUITestSocketDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = socketListenerConfigurationIfEnabled() else {
            payload["socketExpectedPath"] = env["CMUX_SOCKET_PATH"] ?? ""
            payload["socketMode"] = "off"
            payload["socketReady"] = "0"
            payload["socketPingResponse"] = ""
            payload["socketIsRunning"] = "0"
            payload["socketAcceptLoopAlive"] = "0"
            payload["socketPathMatches"] = "0"
            payload["socketPathExists"] = "0"
            payload["socketPathOwnedByListener"] = "0"
            payload["socketFailureSignals"] = "socket_disabled"
            return
        }

        let socketPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
        let pingResponse = health.isHealthy
            ? socketTransport.probeCommand("ping", at: socketPath, timeout: 1.0)
            : nil
        let isReady = health.isHealthy && pingResponse == "PONG"
        var failureSignals = health.failureSignals
        if health.isHealthy && pingResponse != "PONG" {
            failureSignals.append("ping_timeout")
        }

        payload["socketExpectedPath"] = socketPath
        payload["socketMode"] = config.mode.rawValue
        payload["socketReady"] = isReady ? "1" : "0"
        payload["socketPingResponse"] = pingResponse ?? ""
        payload["socketIsRunning"] = health.isRunning ? "1" : "0"
        payload["socketAcceptLoopAlive"] = health.acceptLoopAlive ? "1" : "0"
        payload["socketPathMatches"] = health.socketPathMatches ? "1" : "0"
        payload["socketPathExists"] = health.socketPathExists ? "1" : "0"
        payload["socketPathOwnedByListener"] = health.socketPathOwnedByListener ? "1" : "0"
        payload["socketFailureSignals"] = failureSignals.joined(separator: ",")
    }

    private func appendUITestPortalDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_PORTAL_STATS"] == "1" else { return }

        let stats = TerminalWindowPortalRegistry.debugPortalStats()
        payload["portal_count"] = Self.uiTestStringValue(stats["portal_count"])
        payload["portal_hosted_mapping_count"] = Self.uiTestStringValue(stats["hosted_mapping_count"])
        payload["portal_guarded_bind_blocked_count"] = Self.uiTestStringValue(stats["guarded_bind_blocked_count"])
        if let totals = stats["totals"] as? [String: Any] {
            for (key, value) in totals {
                payload["portal_\(key)"] = Self.uiTestStringValue(value)
            }
        }
    }

    private static func uiTestStringValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value ? "1" : "0"
        case let value as Int:
            return String(value)
        case let value as NSNumber:
            return value.stringValue
        case let value as UUID:
            return value.uuidString
        case .some(let value):
            return String(describing: value)
        case .none:
            return ""
        }
    }

    private func appendUITestRenderDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }

        guard let renderState = currentUITestRenderDiagnostics() else {
            payload["renderStatsAvailable"] = "0"
            payload["renderPanelId"] = ""
            payload["renderDrawCount"] = ""
            payload["renderPresentCount"] = ""
            payload["renderLastPresentTime"] = ""
            payload["renderWindowVisible"] = ""
            payload["renderAppIsActive"] = ""
            payload["renderDesiredFocus"] = ""
            payload["renderIsFirstResponder"] = ""
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            return
        }

        payload["renderStatsAvailable"] = "1"
        payload["renderPanelId"] = renderState.panelId.uuidString
        payload["renderDrawCount"] = String(renderState.drawCount)
        payload["renderPresentCount"] = String(renderState.presentCount)
        payload["renderLastPresentTime"] = String(format: "%.6f", renderState.lastPresentTime)
        payload["renderWindowVisible"] = renderState.windowVisible ? "1" : "0"
        payload["renderAppIsActive"] = renderState.appIsActive ? "1" : "0"
        payload["renderDesiredFocus"] = renderState.desiredFocus ? "1" : "0"
        payload["renderIsFirstResponder"] = renderState.isFirstResponder ? "1" : "0"
        payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    }

    private func currentUITestRenderDiagnostics() -> UITestRenderDiagnosticsSnapshot? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            if let focusedTerminalPanel = workspace.focusedTerminalPanel {
                return focusedTerminalPanel
            }
            return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
        }()

        guard let terminalPanel else { return nil }
        let stats = terminalPanel.hostedView.debugRenderStats()
        return UITestRenderDiagnosticsSnapshot(
            panelId: terminalPanel.id,
            drawCount: stats.drawCount,
            presentCount: stats.presentCount,
            lastPresentTime: stats.lastPresentTime,
            windowVisible: stats.windowOcclusionVisible,
            appIsActive: stats.appIsActive,
            desiredFocus: stats.desiredFocus,
            isFirstResponder: stats.isFirstResponder
        )
    }

    private func moveUITestWindowToTargetDisplayIfNeeded(attempt: Int = 0) {
        let env = ProcessInfo.processInfo.environment
        guard let rawDisplayID = env["CMUX_UI_TEST_TARGET_DISPLAY_ID"],
              let targetDisplayID = UInt32(rawDisplayID) else {
            return
        }

        guard let screen = NSScreen.screens.first(where: { $0.cmuxDisplayID == targetDisplayID }) else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayMissing")
            return
        }

        guard let window = NSApp.windows.first else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayNoWindow")
            return
        }

        let visibleFrame = screen.visibleFrame
        let width = min(window.frame.width, max(visibleFrame.width - 80, 480))
        let height = min(window.frame.height, max(visibleFrame.height - 80, 360))
        let frame = NSRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2),
            width: width,
            height: height
        ).integral

        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if window.screen?.cmuxDisplayID != targetDisplayID, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
            }
            return
        }
        self.writeUITestDiagnosticsIfNeeded(stage: "afterMoveToTargetDisplay")
    }
#endif

}
