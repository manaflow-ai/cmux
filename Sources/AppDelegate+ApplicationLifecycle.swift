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


// MARK: - Activation, termination, single instance, and launch registration
extension AppDelegate {
    func applicationWillBecomeActive(_ notification: Notification) { if !hasVisibleMainTerminalWindow() { _ = mainWindowVisibilityController.orderFrontApplicationWindowsBeforeActivation(windows: mainWindowsForVisibilityController(), reason: .applicationWillBecomeActive) } }

    func applicationDidBecomeActive(_ notification: Notification) {
        let activationWindows = mainWindowsForVisibilityController()
        if mainWindowVisibilityController.finishPendingApplicationActivationRestore(windows: activationWindows, reason: .applicationDidBecomeActive) == nil, !hasVisibleMainTerminalWindow() {
            _ = mainWindowVisibilityController.restoreApplicationWindowsAfterActivation(windows: activationWindows, reason: .applicationDidBecomeActive)
        }
        sentryBreadcrumb("app.didBecomeActive", category: "lifecycle", data: [
            "tabCount": tabManager?.tabs.count ?? 0
        ])
        if TelemetrySettings.enabledForCurrentLaunch && !isRunningUnderXCTestCached {
            PostHogAnalytics.shared.trackActive(reason: "didBecomeActive")
        }

        guard let notificationStore else { return }
        notificationStore.handleApplicationDidBecomeActive()
        guard let tabManager else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }),
           notificationStore.hasUnreadNotificationRequiringPaneFlash(forTabId: tabId, surfaceId: surfaceId) {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let buildFlavor = BuildFlavor.current
        let hasDirtyWorkspaces = hasQuitConfirmationDirtyWorkspaces()
        let confirmQuitMode = QuitWarningSettings.confirmQuitMode()

        StartupBreadcrumbLog.append(
            "appDelegate.shouldTerminate.begin",
            fields: [
                "buildFlavor": buildFlavor.rawValue,
                "confirmQuitMode": confirmQuitMode.rawValue,
                "hasDirtyWorkspaces": hasDirtyWorkspaces ? "1" : "0",
                "quitWarningConfirmed": isQuitWarningConfirmed ? "1" : "0",
                "quitWarningEnabled": QuitWarningSettings.isEnabled() ? "1" : "0"
            ]
        )
        isTerminatingApp = true
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
        ClosedItemHistoryStore.shared.flushPendingSaves()

        // If the user already confirmed via the Cmd+Q shortcut warning dialog,
        // or policy skips the warning, avoid a second alert.
        if !QuitWarningSettings.shouldShowConfirmation(
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            hasDirtyWorkspaces: hasDirtyWorkspaces,
            buildFlavor: buildFlavor
        ) {
            closeAllWebInspectorsBeforeAppTeardown()
            let reason: String
            if isQuitWarningConfirmed {
                reason = "confirmed"
            } else if buildFlavor == .dev {
                reason = "devBuild"
            } else {
                reason = "policy"
            }
            StartupBreadcrumbLog.append("appDelegate.shouldTerminate.terminateNow", fields: ["reason": reason])
            return .terminateNow
        }

        // Show the same confirmation dialog used by the Cmd+Q shortcut path,
        // then reply asynchronously so we can return .terminateLater now.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "dialog.quitCmux.title", defaultValue: "Quit cmux?")
            alert.informativeText = String(localized: "dialog.quitCmux.message", defaultValue: "This will close all windows and workspaces.")
            alert.addButton(withTitle: String(localized: "dialog.quitCmux.quit", defaultValue: "Quit"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")

            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                QuitWarningSettings.setEnabled(false)
            }

            let shouldQuit = response == .alertFirstButtonReturn
            if shouldQuit {
                self.isQuitWarningConfirmed = true
                self.closeAllWebInspectorsBeforeAppTeardown()
                StartupBreadcrumbLog.append("appDelegate.shouldTerminate.reply", fields: ["shouldQuit": "1"])
            } else {
                // Reset so that the next quit attempt can show the dialog again.
                self.isTerminatingApp = false
                StartupBreadcrumbLog.append("appDelegate.shouldTerminate.reply", fields: ["shouldQuit": "0"])
            }
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        StartupBreadcrumbLog.append("appDelegate.shouldTerminate.later")
        return .terminateLater
    }

    func hasQuitConfirmationDirtyWorkspaces() -> Bool {
        var visitedManagers = Set<ObjectIdentifier>()

        func managerHasDirtyWorkspace(_ manager: TabManager?) -> Bool {
            guard let manager else { return false }
            let managerId = ObjectIdentifier(manager)
            guard visitedManagers.insert(managerId).inserted else { return false }
            return manager.tabs.contains(where: { $0.needsConfirmClose() })
        }

        for context in mainWindowContexts.values {
            if managerHasDirtyWorkspace(context.tabManager) {
                return true
            }
        }

        if managerHasDirtyWorkspace(tabManager) {
            return true
        }

        for route in recoverableMainWindowRoutes() {
            if managerHasDirtyWorkspace(route.tabManager) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func closeAllWebInspectorsBeforeAppTeardown() -> Int {
        WebViewInspectorTeardown.closeAllInspectors(in: NSApp.windows)
    }

    func applicationWillTerminate(_ notification: Notification) {
        StartupBreadcrumbLog.append("appDelegate.willTerminate.begin")
        isTerminatingApp = true
        closeAllWebInspectorsBeforeAppTeardown()
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
        ClosedItemHistoryStore.shared.flushPendingSaves()
        stopSessionAutosaveTimer()
        CloudVMActionLauncher.shared.terminateAll()
        CmuxSSHURLProcessLauncher.shared.terminateAll()
        MobileHostService.shared.stop()
        TerminalController.shared.stop()
        GhosttyPasteboardHelper.cleanupAllOwnedTemporaryImageFiles()
        VSCodeServeWebController.shared.stop()
        BrowserProfileStore.shared.flushPendingSaves()
        if TelemetrySettings.enabledForCurrentLaunch {
            PostHogAnalytics.shared.flush()
        }
        ghosttyCrashBreadcrumbTask?.cancel()
        ghosttyCrashBreadcrumbTask = nil
        notificationStore?.clearAll()
        GhosttyCrashBreadcrumb.markCleanExit()
        StartupBreadcrumbLog.append("appDelegate.willTerminate.complete")
        enableSuddenTerminationIfNeeded()
    }

    func applicationWillResignActive(_ notification: Notification) {
        guard !isTerminatingApp else { return }
        clearConfiguredShortcutChordState()
        if Self.shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
        }
    }

    func persistSessionForUpdateRelaunch() {
        isTerminatingApp = true
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
        ClosedItemHistoryStore.shared.flushPendingSaves()
    }

    func configure(
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore,
        sidebarState: SidebarState,
        settingsRuntime: SettingsRuntime,
        auth: MacAuthComposition
    ) {
        self.tabManager = tabManager
        self.settingsRuntime = settingsRuntime
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        self.auth = auth
        VMClient.bootstrap(auth: auth.coordinator)
        PhonePushClient.shared.configure(auth: auth.coordinator)
        MobileHostService.shared.configure(auth: auth.coordinator)
        DeviceRegistryClient.shared.configure(auth: auth.coordinator)
        TerminalController.shared.attachAuth(
            coordinator: auth.coordinator,
            browserSignIn: auth.browserSignIn
        )
        auth.start()
        ensureMobileWorkspaceListObserver(for: tabManager)
        MobileTerminalRenderObserver.shared.start()
        installMobileHostSettingsObserver()
        scheduleGhosttyCrashBreadcrumbIfNeeded(notificationStore: notificationStore)
        disableSuddenTerminationIfNeeded()
        installLifecycleSnapshotObserversIfNeeded()
        prepareStartupSessionSnapshotIfNeeded()
        startSessionAutosaveTimerIfNeeded()
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
        setupTerminalCmdClickUITestIfNeeded()
        setupGotoSplitUITestIfNeeded()
        setupBonsplitTabDragUITestIfNeeded()
        setupTerminalViewportUITestIfNeeded()
        setupMultiWindowNotificationsUITestIfNeeded()
        setupDisplayResolutionUITestDiagnosticsIfNeeded()
        setupPortalStatsUITestDiagnosticsIfNeeded()

        let env = ProcessInfo.processInfo.environment
        if isRunningUnderXCTest(env) || env["CMUX_UI_TEST_MODE"] == "1" {
            scheduleUITestSocketSanityCheckIfNeeded()
        }
#endif
    }

    private func scheduleGhosttyCrashBreadcrumbIfNeeded(notificationStore: TerminalNotificationStore) {
        guard !didScheduleGhosttyCrashBreadcrumbCheck else { return }
        didScheduleGhosttyCrashBreadcrumbCheck = true

        ghosttyCrashBreadcrumbTask = Task { [weak self, weak notificationStore] in
            defer { self?.ghosttyCrashBreadcrumbTask = nil }
            guard let pendingCrash = await GhosttyCrashBreadcrumb.pendingCrashFromDefaultStorage(),
                  !Task.isCancelled,
                  let notificationStore else { return }
            notificationStore.addNotification(
                tabId: GhosttyCrashBreadcrumb.notificationTabId,
                surfaceId: nil,
                title: String(
                    localized: "crashBreadcrumb.title",
                    defaultValue: "cmux crashed during your last session"
                ),
                subtitle: String(
                    localized: "crashBreadcrumb.subtitle",
                    defaultValue: "Diagnostic file saved"
                ),
                body: String(
                    localized: "crashBreadcrumb.body",
                    defaultValue: "Diagnostic file saved. Click to reveal it in Finder."
                ),
                clickAction: .revealInFinder(path: pendingCrash.fileURL.path)
            )
            GhosttyCrashBreadcrumb.markShown(pendingCrash)
        }
    }

    func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    func ensureApplicationIcon() {
        let mode = AppIconSettings.resolvedMode()
        AppIconSettings.applyIcon(mode)
    }

    func scheduleLaunchServicesBundleRegistration(
        bundleURL: URL = Bundle.main.bundleURL.standardizedFileURL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = AppDelegate.enqueueLaunchServicesRegistrationWork,
        register: @escaping (CFURL) -> OSStatus = { url in
            LSRegisterURL(url, true)
        },
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { message, data in
            sentryBreadcrumb(message, category: "startup", data: data)
        }
    ) {
        let normalizedURL = bundleURL.standardizedFileURL
        breadcrumb("launchservices.register.schedule", [
            "bundlePath": normalizedURL.path
        ])

        scheduler {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let registerStatus = register(normalizedURL as CFURL)
            let durationMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())

            breadcrumb("launchservices.register.complete", [
                "bundlePath": normalizedURL.path,
                "status": Int(registerStatus),
                "durationMs": durationMs
            ])

            if registerStatus != noErr {
                NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(normalizedURL.path)")
            }
        }
    }

#if DEBUG
    func scheduleLaunchServicesBundleRegistrationForTesting(
        bundleURL: URL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void,
        register: @escaping (CFURL) -> OSStatus,
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { _, _ in }
    ) {
        scheduleLaunchServicesBundleRegistration(
            bundleURL: bundleURL,
            scheduler: scheduler,
            register: register,
            breadcrumb: breadcrumb
        )
    }
#endif

    func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            StartupBreadcrumbLog.append("singleInstance.enforce.skip", fields: ["reason": "missingBundleId"])
            return
        }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        var terminatedPids: [String] = []

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            terminatedPids.append(String(app.processIdentifier))
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
        StartupBreadcrumbLog.append(
            "singleInstance.enforce.complete",
            fields: [
                "bundleIdentifier": bundleId,
                "currentPid": String(currentPid),
                "terminatedPids": terminatedPids.joined(separator: ",")
            ]
        )
    }

    func observeDuplicateLaunches() {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            StartupBreadcrumbLog.append("singleInstance.observe.skip", fields: ["reason": "missingBundleId"])
            return
        }
        let embeddedCLIURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentPid = ProcessInfo.processInfo.processIdentifier
        StartupBreadcrumbLog.append(
            "singleInstance.observe.install",
            fields: [
                "bundleIdentifier": bundleId,
                "currentPid": String(currentPid)
            ]
        )

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }
            if let executableURL = app.executableURL?
                   .standardizedFileURL
                   .resolvingSymlinksInPath(),
               executableURL == embeddedCLIURL {
                return
            }

            StartupBreadcrumbLog.append(
                "singleInstance.observe.terminateDuplicate",
                fields: [
                    "duplicatePid": String(app.processIdentifier),
                    "duplicateBundleIdentifier": app.bundleIdentifier ?? "nil"
                ]
            )
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

}
