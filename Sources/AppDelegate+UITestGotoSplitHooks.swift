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



// MARK: - UITest hooks: goto-split setup, recorders, and test data (DEBUG)
extension AppDelegate {
#if DEBUG
    func setupGotoSplitUITestIfNeeded() {
        guard !didSetupGotoSplitUITest else { return }
        didSetupGotoSplitUITest = true
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1" {
            installGotoSplitUITestFocusObserversIfNeeded()
            startGotoSplitRecordOnlyRecorder()
            return
        }
        guard env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }

        let useGhosttyConfig = env["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] == "1"

        if useGhosttyConfig {
            // Keep the test hermetic: ensure the app does not accidentally pass using a persisted
            // KeyboardShortcutSettings override instead of the Ghostty config-trigger path.
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusLeftKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusRightKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusUpKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusDownKey)
        } else {
            // For this UI test we want a letter-based shortcut (Cmd+Ctrl+H) to drive pane navigation,
            // since arrow keys can't be recorded by the shortcut recorder.
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
                for: .focusLeft
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
                for: .focusRight
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
                for: .focusUp
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
                for: .focusDown
            )
        }

        installGotoSplitUITestFocusObserversIfNeeded()

        // On the VM, launching/initializing multiple windows can occasionally take longer than a
        // few seconds; keep the deadline generous so the test doesn't flake.
        let deadline = Date().addingTimeInterval(20.0)
        func hasMainTerminalWindow() -> Bool {
            NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeGotoSplitTestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard hasMainTerminalWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }
            guard let tabManager = self.tabManager else { return }

            let tab = tabManager.addTab()
            guard let initialPanelId = tab.focusedPanelId else {
                self.writeGotoSplitTestData(["setupError": "Missing initial panel id"])
                return
            }

            let requestedBrowserURL = env["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = requestedBrowserURL.flatMap { rawURL in
                guard !rawURL.isEmpty else { return nil }
                return URL(string: rawURL)
            } ?? URL(string: "https://example.com")
            guard let url else {
                self.writeGotoSplitTestData(["setupError": "Invalid browser URL"])
                return
            }
            guard let browserPanelId = tabManager.newBrowserSplit(
                tabId: tab.id,
                fromPanelId: initialPanelId,
                orientation: .horizontal,
                url: url
            ) else {
                self.writeGotoSplitTestData(["setupError": "Failed to create browser split"])
                return
            }

            self.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func isGotoSplitUITestRecordingEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" || env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1"
    }

    private func gotoSplitUITestDataPath() -> String? {
        guard isGotoSplitUITestRecordingEnabled() else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return path
    }

    private func gotoSplitFindStateSnapshot(for workspace: Workspace) -> [String: String] {
        var updates: [String: String] = [
            "focusedPaneId": workspace.bonsplitController.focusedPaneId?.description ?? ""
        ]

        if let focusedPanelId = workspace.focusedPanelId {
            updates["focusedPanelId"] = focusedPanelId.uuidString
            if let terminal = workspace.terminalPanel(for: focusedPanelId) {
                updates["focusedPanelKind"] = "terminal"
                updates["focusedTerminalFindNeedle"] = terminal.searchState?.needle ?? ""
                updates["focusedBrowserFindNeedle"] = ""
            } else if let browser = workspace.browserPanel(for: focusedPanelId) {
                updates["focusedPanelKind"] = "browser"
                updates["focusedBrowserFindNeedle"] = browser.searchState?.needle ?? ""
                updates["focusedTerminalFindNeedle"] = ""
            } else {
                updates["focusedPanelKind"] = "other"
                updates["focusedTerminalFindNeedle"] = ""
                updates["focusedBrowserFindNeedle"] = ""
            }
        } else {
            updates["focusedPanelId"] = ""
            updates["focusedPanelKind"] = "none"
            updates["focusedTerminalFindNeedle"] = ""
            updates["focusedBrowserFindNeedle"] = ""
        }

        let terminalWithFind = workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .first(where: { $0.searchState != nil })
        updates["terminalFindPanelId"] = terminalWithFind?.id.uuidString ?? ""
        updates["terminalFindNeedle"] = terminalWithFind?.searchState?.needle ?? ""
        updates["terminalFindVisible"] = terminalWithFind == nil ? "false" : "true"

        let browserWithFind = workspace.panels.values
            .compactMap { $0 as? BrowserPanel }
            .first(where: { $0.searchState != nil })
        updates["browserFindPanelId"] = browserWithFind?.id.uuidString ?? ""
        updates["browserFindNeedle"] = browserWithFind?.searchState?.needle ?? ""
        updates["browserFindSelected"] = browserWithFind?.searchState?.selected.map {
            String($0 + 1)
        } ?? ""
        updates["browserFindTotal"] = browserWithFind?.searchState?.total.map(String.init) ?? ""
        updates["browserFindVisible"] = browserWithFind == nil ? "false" : "true"

        let currentResponder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
        updates["firstResponderTerminalPanelId"] =
            cmuxOwningGhosttyView(for: currentResponder)?.terminalSurface?.id.uuidString ?? ""

        updates.merge(cmuxFindResponderSnapshot()) { _, new in new }
        return updates
    }

    func startGotoSplitUITestRecorder(browserPanelId: UUID) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        gotoSplitUITestRecorder?.cancel()
        gotoSplitUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordGotoSplitUITestState(browserPanelId: browserPanelId)
        }
        gotoSplitUITestRecorder = timer
        timer.resume()
    }

    private func startGotoSplitRecordOnlyRecorder() {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        gotoSplitUITestRecorder?.cancel()
        gotoSplitUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let workspace = self.tabManager?.selectedWorkspace else { return }
                self.writeGotoSplitTestData(self.gotoSplitFindStateSnapshot(for: workspace))
            }
        }
        gotoSplitUITestRecorder = timer
        timer.resume()
    }

    private func recordGotoSplitUITestState(browserPanelId: UUID) {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            return
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["browserPageTitle"] = browserPanel.webView.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updates["browserPageURL"] = browserPanel.preferredURLStringForOmnibar() ?? ""
        updates["browserFocusModeActive"] = browserPanel.isBrowserFocusModeActive ? "true" : "false"
        updates["browserFocusModeExitArmed"] = browserPanel.isBrowserFocusModeExitArmed ? "true" : "false"
        writeGotoSplitTestData(updates)
    }

    func paneIdsForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) -> (browser: PaneID, terminal: PaneID)? {
        let paneIds = tab.bonsplitController.allPaneIds
        guard paneIds.count >= 2 else { return nil }

        var browserPane: PaneID?
        var terminalPane: PaneID?
        for paneId in paneIds {
            guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = tab.panelIdFromSurfaceId(selected.id) else { continue }
            if panelId == browserPanelId {
                browserPane = paneId
            } else if terminalPane == nil {
                terminalPane = paneId
            }
        }

        guard let browserPane, let terminalPane else { return nil }
        return (browserPane, terminalPane)
    }

    func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let tabManager, let workspace = tabManager.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastMoveDirection"] = directionValue
        writeGotoSplitTestData(updates)
    }

    func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastSplitDirection"] = directionValue
        updates["paneCountAfterSplit"] = String(workspace.bonsplitController.allPaneIds.count)
        writeGotoSplitTestData(updates)
    }

    func recordGotoSplitZoomIfNeeded(tabManager: TabManager? = nil) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = (tabManager ?? self.tabManager)?.selectedWorkspace else { return }

        func snapshot(for workspace: Workspace) -> ([String: String], Bool) {
            let browserPanel = workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
            let otherTerminal = workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
            let browserSnapshot = browserPanel.flatMap { BrowserWindowPortalRegistry.debugSnapshot(for: $0.webView) }

            var updates = self.gotoSplitFindStateSnapshot(for: workspace)
            updates["splitZoomedAfterToggle"] = workspace.bonsplitController.isSplitZoomed ? "true" : "false"
            updates["zoomedPaneIdAfterToggle"] = workspace.bonsplitController.zoomedPaneId?.description ?? ""
            updates["browserPanelIdAfterToggle"] = browserPanel?.id.uuidString ?? ""
            updates["browserContainerHiddenAfterToggle"] = browserSnapshot.map { $0.containerHidden ? "true" : "false" } ?? ""
            updates["browserVisibleFlagAfterToggle"] = browserSnapshot.map { $0.visibleInUI ? "true" : "false" } ?? ""
            updates["browserFrameAfterToggle"] = browserSnapshot.map {
                String(
                    format: "%.1f,%.1f %.1fx%.1f",
                    $0.frameInWindow.origin.x,
                    $0.frameInWindow.origin.y,
                    $0.frameInWindow.size.width,
                    $0.frameInWindow.size.height
                )
            } ?? ""
            updates["otherTerminalPanelIdAfterToggle"] = otherTerminal?.id.uuidString ?? ""
            updates["otherTerminalHostHiddenAfterToggle"] = otherTerminal.map { $0.hostedView.isHidden ? "true" : "false" } ?? ""
            updates["otherTerminalVisibleFlagAfterToggle"] = otherTerminal.map { $0.hostedView.debugPortalVisibleInUI ? "true" : "false" } ?? ""
            updates["otherTerminalFrameAfterToggle"] = otherTerminal.map {
                let frame = $0.hostedView.debugPortalFrameInWindow
                return String(
                    format: "%.1f,%.1f %.1fx%.1f",
                    frame.origin.x,
                    frame.origin.y,
                    frame.size.width,
                    frame.size.height
                )
            } ?? ""

            let settled: Bool = {
                if workspace.bonsplitController.isSplitZoomed {
                    if let focusedPanelId = workspace.focusedPanelId,
                       workspace.terminalPanel(for: focusedPanelId) != nil {
                        guard let browserSnapshot else { return false }
                        return browserSnapshot.containerHidden && !browserSnapshot.visibleInUI
                    }
                    guard let otherTerminal else { return true }
                    return otherTerminal.hostedView.isHidden && !otherTerminal.hostedView.debugPortalVisibleInUI
                }
                let browserRestored = browserSnapshot.map { !$0.containerHidden && $0.visibleInUI } ?? true
                let terminalRestored = otherTerminal.map {
                    !$0.hostedView.isHidden && $0.hostedView.debugPortalVisibleInUI
                } ?? true
                return browserRestored && terminalRestored
            }()

            return (updates, settled)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
            panelsCancellable = nil
        }

        @MainActor
        func finish(with updates: [String: String]) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeGotoSplitTestData(updates)
        }

        @MainActor
        func evaluate() {
            guard !resolved, let currentWorkspace = (tabManager ?? self.tabManager)?.selectedWorkspace else { return }
            let (updates, settled) = snapshot(for: currentWorkspace)
            guard settled else { return }
            finish(with: updates)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = workspace.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved, let currentWorkspace = (tabManager ?? self.tabManager)?.selectedWorkspace else { return }
                finish(with: snapshot(for: currentWorkspace).0)
            }
        }
        Task { @MainActor in evaluate() }
    }

    func writeGotoSplitTestData(_ updates: [String: String]) {
        guard let path = gotoSplitUITestDataPath() else { return }
        var payload = loadGotoSplitTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func loadGotoSplitTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

#endif
}
