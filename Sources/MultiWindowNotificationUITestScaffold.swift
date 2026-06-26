#if DEBUG
import AppKit
import Combine
import CmuxWorkspaces
import Foundation
import CmuxTestSupport

/// Records the multi-window notification routing UI-test state for the
/// `CMUX_UI_TEST_MULTI_WINDOW_NOTIF_*` XCUITest scenario.
///
/// This is the app-target conformer of ``UITestRecording`` for the
/// multi-window notification scenario. It owns the live `AppDelegate` it drives
/// the two-window notification fixture through (creating a second main window,
/// seeding notifications, focusing the source terminal, probing the control
/// socket) and reads window/tab/surface/socket state from. It cannot live in
/// `CmuxTestSupport` because a lower package cannot reference
/// `AppDelegate`/`TabManager`/`Workspace`/`TerminalNotificationStore`/the
/// control-socket internals.
///
/// ``installIfNeeded()`` is gated by `CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP`
/// (plus a non-empty `CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH`) and is a no-op in
/// production; it carries its own one-shot guard so the composition root can
/// call it unconditionally during launch.
///
/// Beyond install, the recorder exposes the live focus / open-failure hooks the
/// rest of the app calls when a notification is opened:
/// ``recordFocusIfNeeded(windowId:tabId:surfaceId:sidebarSelection:)`` (from the
/// notification-open success path) and
/// ``recordOpenFailureIfNeeded(tabId:surfaceId:notificationId:reason:)`` (from
/// the open-failure paths). These read live `mainWindowContexts` state, so they
/// stay on the recorder while `AppDelegate` only forwards.
///
/// The capture-file shape (a `[String: String]` object merged and re-serialized
/// with unsorted keys) is byte-identical to the legacy `AppDelegate`
/// implementation, routed through the single tested writer
/// ``UITestKeyValueCaptureFile``. The route-CLI step
/// (`runMultiWindowWindowRouteCLIIfNeeded`) stays in `AppDelegate` because it
/// drives the `MultiWindowRouter` / `MultiWindowWindowRouteCoordinator` and the
/// control socket; the recorder calls back into it through `appDelegate`.
@MainActor
final class MultiWindowNotificationUITestScaffold: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSetup = false

    /// Creates a recorder bound to `appDelegate`, reading scenario gates from
    /// `environment`.
    ///
    /// - Parameters:
    ///   - appDelegate: The live app delegate whose windows, notification store,
    ///     and control socket the recorder drives.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    func installIfNeeded() {
        guard !didSetup else { return }
        didSetup = true

        let env = environment
        guard env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        try? FileManager.default.removeItem(atPath: path)

        func waitForContexts(minCount: Int, _ completion: @escaping () -> Void) {
            let isReady = {
                self.appDelegate.registeredMainWindows.count >= minCount &&
                    self.appDelegate.registeredMainWindows.allSatisfy { $0.window != nil }
            }
            guard !isReady() else {
                completion()
                return
            }

            var resolved = false
            var observer: NSObjectProtocol?
            let finish = {
                guard !resolved else { return }
                resolved = true
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                completion()
            }
            observer = NotificationCenter.default.addObserver(
                forName: .mainWindowContextsDidChange,
                object: self.appDelegate,
                queue: .main
            ) { _ in
                if isReady() {
                    finish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                if isReady() {
                    finish()
                } else if let observer, !resolved {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        func waitForSurfaceId(
            on tabManager: TabManager,
            tabId: UUID,
            timeout: TimeInterval = 8.0,
            _ completion: @escaping (UUID) -> Void
        ) {
            func resolvedSurfaceId() -> UUID? {
                if let surfaceId = tabManager.focusedPanelId(for: tabId) {
                    return surfaceId
                }

                guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                    return nil
                }

                if let terminalPanelId = workspace.focusedTerminalPanel?.id {
                    return terminalPanelId
                }

                if let terminalPanelId = workspace.terminalPanelForConfigInheritance()?.id {
                    return terminalPanelId
                }

                return workspace.panels.values
                    .compactMap { ($0 as? TerminalPanel)?.id }
                    .sorted(by: { $0.uuidString < $1.uuidString })
                    .first
            }

            if let surfaceId = resolvedSurfaceId() {
                completion(surfaceId)
                return
            }

            var resolved = false
            var focusObserver: NSObjectProtocol?
            var surfaceReadyObserver: NSObjectProtocol?
            var tabsObservation: WorkspacesObservation?
            var panelsCancellable: AnyCancellable?
            var observedWorkspaceId: UUID?

            func cleanup() {
                if let focusObserver {
                    NotificationCenter.default.removeObserver(focusObserver)
                }
                if let surfaceReadyObserver {
                    NotificationCenter.default.removeObserver(surfaceReadyObserver)
                }
                tabsObservation?.cancel()
                panelsCancellable?.cancel()
            }

            func attemptResolve() {
                guard !resolved else { return }
                if let workspace = tabManager.tabs.first(where: { $0.id == tabId }),
                   observedWorkspaceId != workspace.id {
                    observedWorkspaceId = workspace.id
                    panelsCancellable?.cancel()
                    panelsCancellable = workspace.panelsPublisher
                        .map { _ in () }
                        .sink { _ in attemptResolve() }
                }
                if let surfaceId = resolvedSurfaceId() {
                    resolved = true
                    cleanup()
                    completion(surfaceId)
                }
            }

            tabsObservation = tabManager.workspaces.observeTabs { attemptResolve() }
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tabId else { return }
                attemptResolve()
            }
            surfaceReadyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                      workspaceId == tabId else { return }
                attemptResolve()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !resolved {
                    cleanup()
                }
            }
            attemptResolve()
        }

        waitForContexts(minCount: 1) { [weak self] in
            guard let self else { return }
            guard let window1 = self.appDelegate.registeredMainWindows.first else { return }
            guard let tabId1 = window1.tabManager.selectedTabId ?? window1.tabManager.tabs.first?.id else { return }

            // Create a second main terminal window.
            self.appDelegate.openNewMainWindow(nil)

            waitForContexts(minCount: 2) { [weak self] in
                guard let self else { return }
                let contexts = Array(self.appDelegate.registeredMainWindows)
                guard let window2 = contexts.first(where: { $0.windowId != window1.windowId }) else { return }
                guard let tabId2 = window2.tabManager.selectedTabId ?? window2.tabManager.tabs.first?.id else { return }
                waitForSurfaceId(on: window1.tabManager, tabId: tabId1) { [weak self] surfaceId1 in
                    guard let self else { return }
                    waitForSurfaceId(on: window2.tabManager, tabId: tabId2) { [weak self] surfaceId2 in
                    guard let self else { return }
                    guard let store = self.appDelegate.notificationStore else { return }

                    // Ensure the target window is currently showing the Notifications overlay,
                    // so opening a notification must switch it back to the terminal UI.
                    self.appDelegate.sidebarSelectionState(for: window2).selection = .notifications

                    // Create notifications for both windows. Ensure W2 isn't suppressed just because it's focused.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    store.addNotification(tabId: tabId2, surfaceId: nil, title: "W2", subtitle: "multiwindow", body: "")
                    AppFocusState.overrideIsFocused = prevOverride

                    // Insert after W2 so it becomes "latest unread" (first in list).
                    store.addNotification(tabId: tabId1, surfaceId: nil, title: "W1", subtitle: "multiwindow", body: "")

                    let notif1 = store.notifications.first(where: { $0.tabId == tabId1 && $0.title == "W1" })
                    let notif2 = store.notifications.first(where: { $0.tabId == tabId2 && $0.title == "W2" })

                    self.writeData([
                        "window1Id": window1.windowId.uuidString,
                        "window2Id": window2.windowId.uuidString,
                        "window2InitialSidebarSelection": "notifications",
                        "tabId1": tabId1.uuidString,
                        "tabId2": tabId2.uuidString,
                        "surfaceId1": surfaceId1.uuidString,
                        "surfaceId2": surfaceId2.uuidString,
                        "notifId1": notif1?.id.uuidString ?? "",
                        "notifId2": notif2?.id.uuidString ?? "",
                        "expectedLatestWindowId": window1.windowId.uuidString,
                        "expectedLatestTabId": tabId1.uuidString,
                    ], at: path)
                    self.prepareSourceTerminalIfNeeded(
                        at: path,
                        windowId: window1.windowId,
                        tabManager: window1.tabManager,
                        tabId: tabId1,
                        surfaceId: surfaceId1
                    )
                    self.publishSocketStateIfNeeded(
                        at: path,
                        window1Id: window1.windowId,
                        window2Id: window2.windowId
                    )
                }
                }
            }
        }
    }

    private func prepareSourceTerminalIfNeeded(
        at path: String,
        windowId: UUID,
        tabManager: TabManager,
        tabId: UUID,
        surfaceId: UUID
    ) {
        let env = environment
        guard env["CMUX_UI_TEST_NOTIFY_SOURCE_TERMINAL_READY"] == "1" else { return }

        writeData([
            "sourceTerminalReady": "pending",
            "sourceTerminalFocusFailure": "",
        ], at: path)

        let deadline = Date().addingTimeInterval(8.0)

        func publish(ready: Bool, failure: String = "") {
            writeData([
                "sourceTerminalReady": ready ? "1" : "0",
                "sourceTerminalFocusFailure": failure,
            ], at: path)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var selectedTabObservation: WorkspacesObservation?
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            selectedTabObservation?.cancel()
            panelsCancellable?.cancel()
        }

        func attemptFocus() {
            guard !resolved else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "workspace_missing")
                return
            }
            panelsCancellable?.cancel()
            panelsCancellable = workspace.panelsPublisher
                .map { _ in () }
                .sink { _ in attemptFocus() }
            guard let terminalPanel = workspace.terminalPanel(for: surfaceId) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "terminal_missing")
                return
            }

            let isWindowFrontmost = {
                guard let window = self.appDelegate.mainWindow(for: windowId) else { return false }
                return NSApp.keyWindow === window || NSApp.mainWindow === window
            }()
            if isWindowFrontmost && terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                resolved = true
                cleanup()
                publish(ready: true)
                return
            }

            guard Date() < deadline else {
                resolved = true
                cleanup()
                publish(
                    ready: false,
                    failure: isWindowFrontmost ? "terminal_not_first_responder" : "window_not_frontmost"
                )
                return
            }

            _ = self.appDelegate.focusMainWindow(windowId: windowId)
            if let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
                tabManager.selectTab(tab)
                tabManager.focusSurface(tabId: tabId, surfaceId: surfaceId)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: appDelegate,
            queue: .main
        ) { _ in
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  workspaceId == tabId,
                  readySurfaceId == surfaceId else { return }
            attemptFocus()
        })
        selectedTabObservation = tabManager.workspaces.observeSelectedTabId { attemptFocus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if !resolved {
                attemptFocus()
            }
        }
        attemptFocus()
    }

    private func publishSocketStateIfNeeded(
        at path: String,
        window1Id: UUID? = nil,
        window2Id: UUID? = nil
    ) {
        let env = environment
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = appDelegate.socketListenerConfigurationIfEnabled() else {
            writeData([
                "socketExpectedPath": env["CMUX_SOCKET_PATH"] ?? "",
                "socketMode": "off",
                "socketReady": "0",
                "socketPingResponse": "",
                "socketIsRunning": "0",
                "socketAcceptLoopAlive": "0",
                "socketPathMatches": "0",
                "socketPathExists": "0",
                "socketPathOwnedByListener": "0",
                "socketFailureSignals": "socket_disabled",
            ], at: path)
            return
        }

        writeData([
            "socketExpectedPath": config.path,
            "socketMode": config.mode.rawValue,
            "socketReady": "pending",
            "socketPingResponse": "",
        ], at: path)

        let socketPath = config.path
        let socketMode = config.mode.rawValue
        var observer: NSObjectProtocol?
        var timeoutWorkItem: DispatchWorkItem?

        func publishCurrentState(isTimedOut: Bool) {
            let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
            let dataPath = path
            let socketTransport = self.appDelegate.socketTransport
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let pingResponse = health.isHealthy
                    ? socketTransport.probeCommand("ping", at: socketPath, timeout: 1.0)
                    : nil
                let isReady = health.isHealthy && pingResponse == "PONG"
                let failureSignals = {
                    var signals = health.failureSignals
                    if health.isHealthy && pingResponse != "PONG" {
                        signals.append("ping_timeout")
                    }
                    return signals.joined(separator: ",")
                }()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.writeData([
                        "socketExpectedPath": socketPath,
                        "socketMode": socketMode,
                        "socketReady": isReady ? "1" : (isTimedOut ? "0" : "pending"),
                        "socketPingResponse": pingResponse ?? "",
                        "socketIsRunning": health.isRunning ? "1" : "0",
                        "socketAcceptLoopAlive": health.acceptLoopAlive ? "1" : "0",
                        "socketPathMatches": health.socketPathMatches ? "1" : "0",
                        "socketPathExists": health.socketPathExists ? "1" : "0",
                        "socketPathOwnedByListener": health.socketPathOwnedByListener ? "1" : "0",
                        "socketFailureSignals": failureSignals,
                    ], at: dataPath)
                    if isReady, let window1Id, let window2Id {
                        self.appDelegate.runMultiWindowWindowRouteCLIIfNeeded(
                            at: dataPath,
                            window1Id: window1Id,
                            window2Id: window2Id,
                            socketPath: socketPath
                        )
                    }
                    guard isReady || isTimedOut else { return }
                    timeoutWorkItem?.cancel()
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                }
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .socketListenerDidStart,
            object: TerminalController.shared,
            queue: .main
        ) { notification in
            let startedPath = notification.userInfo?["path"] as? String
            guard startedPath == socketPath else { return }
            publishCurrentState(isTimedOut: false)
        }

        let timeout = DispatchWorkItem {
            publishCurrentState(isTimedOut: true)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: timeout)

        appDelegate.restartSocketListenerIfEnabled(source: "uiTest.multiWindowNotifications.setup")
        publishCurrentState(isTimedOut: false)
    }

    /// Live navigation hook: records the focused window/tab/surface and sidebar
    /// selection after a multi-window notification open succeeds.
    func recordFocusIfNeeded(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        sidebarSelection: SidebarSelection
    ) {
        guard let path = environment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }
        let sidebarSelectionString: String = {
            switch sidebarSelection {
            case .tabs: return "tabs"
            case .notifications: return "notifications"
            }
        }()
        writeData([
            "focusToken": UUID().uuidString,
            "focusedWindowId": windowId.uuidString,
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId?.uuidString ?? "",
            "focusedSidebarSelection": sidebarSelectionString,
        ], at: path)
    }

    /// Live navigation hook: records an open-failure with a snapshot of every
    /// registered main-window context, for the multi-window notification
    /// open-failure XCUITest assertions.
    func recordOpenFailureIfNeeded(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        reason: String
    ) {
        let env = environment
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        let contextSummaries: [String] = appDelegate.registeredMainWindows.map { ctx in
            let tabIds = ctx.tabManager.tabs.map { $0.id.uuidString }.joined(separator: ",")
            let hasWindow = (ctx.window != nil) ? "1" : "0"
            return "windowId=\(ctx.windowId.uuidString) hasWindow=\(hasWindow) tabs=[\(tabIds)]"
        }

        writeData([
            "focusToken": UUID().uuidString,
            "openFailureTabId": tabId.uuidString,
            "openFailureSurfaceId": surfaceId?.uuidString ?? "",
            "openFailureNotificationId": notificationId?.uuidString ?? "",
            "openFailureReason": reason,
            "openFailureContexts": contextSummaries.joined(separator: "; "),
        ], at: path)
    }

    /// Merges `updates` into the multi-window notification capture file at
    /// `path`. The byte-faithful unsorted-keys merge/load/write lives in
    /// ``UITestKeyValueCaptureFile``; this shim only carries the live path the
    /// app-coupled harness orchestration computed.
    private func writeData(_ updates: [String: String], at path: String) {
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }
}
#endif
