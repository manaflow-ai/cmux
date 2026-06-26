#if DEBUG
import AppKit
import Bonsplit
import CmuxFoundation
import CmuxPanes
import CmuxTestSupport
import Combine
import Foundation
import WebKit

/// Records the goto-split navigation / find-state UI-test data for the
/// `CMUX_UI_TEST_GOTO_SPLIT_*` XCUITest scenarios.
///
/// This is the app-target conformer of ``UITestRecording`` for the goto-split
/// scenarios. It owns the live `AppDelegate` it reads workspace / pane /
/// browser / first-responder state from, drives the browser-split fixture
/// through, and seeds page inputs in via `WKWebView` JavaScript, which is why
/// it cannot live in `CmuxTestSupport` (a lower package cannot reference
/// `AppDelegate`/`TabManager`/`Workspace`/`BrowserPanel`). ``installIfNeeded()``
/// is gated by `CMUX_UI_TEST_GOTO_SPLIT_SETUP` / `CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY`
/// and is a no-op in production; it carries its own one-shot guard so the
/// composition root can call it unconditionally during launch.
///
/// Beyond install, the recorder exposes the live navigation hooks the rest of
/// the app calls when a goto-split move / split / zoom happens
/// (``recordMoveIfNeeded(direction:)``, ``recordSplitIfNeeded(direction:)``,
/// ``recordZoomIfNeeded(tabManager:)``). These need live first-responder /
/// portal-geometry state, so the recorder reads it while `AppDelegate` only
/// forwards. The capture file shape (a `[String: String]` object merged and
/// re-serialized with unsorted keys) is byte-identical to the legacy
/// `AppDelegate` implementation this was lifted from.
@MainActor
final class GotoSplitUITestRecorder: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSetup = false
    private let pollTimer = UITestPollTimer()
    private var focusObservers: [NSObjectProtocol] = []

    /// Creates a recorder bound to `appDelegate`, reading scenario gates from
    /// `environment`.
    ///
    /// - Parameters:
    ///   - appDelegate: The live app delegate whose workspaces / browser panels
    ///     the recorder drives.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    private var tabManager: TabManager? { appDelegate.tabManager }

    func installIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        let env = environment
        if env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1" {
            installFocusObserversIfNeeded()
            startRecordOnlyRecorder()
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

        installFocusObserversIfNeeded()

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
                writeData(["setupError": "Timed out waiting for main window"])
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
                self.writeData(["setupError": "Missing initial panel id"])
                return
            }

            let requestedBrowserURL = env["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = requestedBrowserURL.flatMap { rawURL in
                guard !rawURL.isEmpty else { return nil }
                return URL(string: rawURL)
            } ?? URL(string: "https://example.com")
            guard let url else {
                self.writeData(["setupError": "Invalid browser URL"])
                return
            }
            guard let browserPanelId = tabManager.newBrowserSplit(
                tabId: tab.id,
                fromPanelId: initialPanelId,
                orientation: .horizontal,
                url: url
            ) else {
                self.writeData(["setupError": "Failed to create browser split"])
                return
            }

            self.focusWebView(tab: tab, browserPanelId: browserPanelId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func isRecordingEnabled() -> Bool {
        environment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1"
            || environment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1"
    }

    private func dataPath() -> String? {
        guard isRecordingEnabled() else { return nil }
        guard let path = environment["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return path
    }

    private func findStateSnapshot(for workspace: Workspace) -> [String: String] {
        let focusedPanel: GotoSplitFindStateSnapshot.FocusedPanel
        if let focusedPanelId = workspace.focusedPanelId {
            if let terminal = workspace.terminalPanel(for: focusedPanelId) {
                focusedPanel = .terminal(
                    panelId: focusedPanelId,
                    findNeedle: terminal.searchState?.needle ?? ""
                )
            } else if let browser = workspace.browserPanel(for: focusedPanelId) {
                focusedPanel = .browser(
                    panelId: focusedPanelId,
                    findNeedle: browser.searchState?.needle ?? ""
                )
            } else {
                focusedPanel = .other(panelId: focusedPanelId)
            }
        } else {
            focusedPanel = .none
        }

        let terminalWithFind = workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .first(where: { $0.searchState != nil })
        let terminalFind = terminalWithFind.map {
            GotoSplitFindStateSnapshot.TerminalFind(
                panelId: $0.id,
                needle: $0.searchState?.needle ?? ""
            )
        }

        let browserWithFind = workspace.panels.values
            .compactMap { $0 as? BrowserPanel }
            .first(where: { $0.searchState != nil })
        let browserFind = browserWithFind.map {
            GotoSplitFindStateSnapshot.BrowserFind(
                panelId: $0.id,
                needle: $0.searchState?.needle ?? "",
                selected: $0.searchState?.selected,
                total: $0.searchState?.total
            )
        }

        let currentResponder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
        let firstResponderTerminalPanelId =
            cmuxOwningGhosttyView(for: currentResponder)?.terminalSurface?.id

        let snapshot = GotoSplitFindStateSnapshot(
            focusedPaneId: workspace.bonsplitController.focusedPaneId?.description ?? "",
            focusedPanel: focusedPanel,
            terminalFind: terminalFind,
            browserFind: browserFind,
            firstResponderTerminalPanelId: firstResponderTerminalPanelId
        )

        var updates = snapshot.captureFields
        updates.merge(cmuxFindResponderSnapshot()) { _, new in new }
        return updates
    }

    private func focusWebView(tab: Workspace, browserPanelId: UUID) {
        guard tab.browserPanel(for: browserPanelId) != nil else {
            writeData([
                "webViewFocused": "false",
                "setupError": "Browser panel missing"
            ])
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
        }

        func recordFocusedState() {
            guard !resolved else { return }
            guard let panel = tab.browserPanel(for: browserPanelId) else {
                resolved = true
                cleanup()
                writeData([
                    "webViewFocused": "false",
                    "setupError": "Browser panel missing"
                ])
                return
            }

            tab.focusPanel(browserPanelId)

            guard appDelegate.isWebViewFocused(panel),
                  let (browserPaneId, terminalPaneId) = paneIds(
                    tab: tab,
                    browserPanelId: browserPanelId
                  ) else {
                return
            }

            resolved = true
            cleanup()
            self.startRecorder(browserPanelId: browserPanelId)
            let shortcuts = appDelegate.ghosttyGotoSplitShortcutDisplayStrings
            writeData([
                "browserPanelId": browserPanelId.uuidString,
                "browserPaneId": browserPaneId.description,
                "terminalPaneId": terminalPaneId.description,
                "initialPaneCount": String(tab.bonsplitController.allPaneIds.count),
                "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                "ghosttyGotoSplitLeftShortcut": shortcuts.left,
                "ghosttyGotoSplitRightShortcut": shortcuts.right,
                "ghosttyGotoSplitUpShortcut": shortcuts.up,
                "ghosttyGotoSplitDownShortcut": shortcuts.down,
                "webViewFocused": "true"
            ])
            if environment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] == "1" {
                setupFocusedInput(panel: panel)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in recordFocusedState() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == browserPanelId else { return }
            Task { @MainActor in recordFocusedState() }
        })
        panelsCancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in Task { @MainActor in recordFocusedState() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            if !resolved {
                cleanup()
                self.writeData([
                    "webViewFocused": "false",
                    "setupError": "Timed out waiting for WKWebView focus"
                ])
            }
        }

        recordFocusedState()
    }

    private func startRecorder(browserPanelId: UUID) {
        guard isRecordingEnabled() else { return }
        pollTimer.start { [weak self] in
            self?.recordState(browserPanelId: browserPanelId)
        }
    }

    private func startRecordOnlyRecorder() {
        guard isRecordingEnabled() else { return }
        pollTimer.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let workspace = self.tabManager?.selectedWorkspace else { return }
                self.writeData(self.findStateSnapshot(for: workspace))
            }
        }
    }

    private func recordState(browserPanelId: UUID) {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            return
        }

        var updates = findStateSnapshot(for: workspace)
        updates["browserPageTitle"] = browserPanel.webView.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updates["browserPageURL"] = browserPanel.preferredURLStringForOmnibar() ?? ""
        updates["browserFocusModeActive"] = browserPanel.isBrowserFocusModeActive ? "true" : "false"
        updates["browserFocusModeExitArmed"] = browserPanel.isBrowserFocusModeExitArmed ? "true" : "false"
        writeData(updates)
    }

    private func paneIds(tab: Workspace, browserPanelId: UUID) -> (browser: PaneID, terminal: PaneID)? {
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

    private func installFocusObserversIfNeeded() {
        guard focusObservers.isEmpty else { return }

        focusObservers.append(NotificationCenter.default.addObserver(
            forName: .browserFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let panelId = notification.object as? UUID else { return }
            Task { @MainActor in
                guard let self else { return }
                self.recordWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarFocus")
                self.recordActiveElement(panelId: panelId, keyPrefix: "addressBarFocus")
            }
        })

        focusObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidExitAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let panelId = notification.object as? UUID else { return }
            Task { @MainActor in
                guard let self else { return }
                self.recordWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarExit")
                self.recordActiveElement(panelId: panelId, keyPrefix: "addressBarExit")
            }
        })
    }

    private func recordWebViewFocus(panelId: UUID, key: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        guard key.contains("Exit") else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeData([
                    key: self.appDelegate.isWebViewFocused(panel) ? "true" : "false",
                    "\(key)PanelId": panelId.uuidString
                ])
            }
            return
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
        func finish(with focused: Bool) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeData([
                key: focused ? "true" : "false",
                "\(key)PanelId": panelId.uuidString
            ])
        }

        @MainActor
        func evaluate() {
            guard !resolved,
                  let currentTabManager = self.tabManager,
                  let currentTab = currentTabManager.selectedWorkspace,
                  let currentPanel = currentTab.browserPanel(for: panelId) else {
                return
            }
            guard self.appDelegate.isWebViewFocused(currentPanel) else { return }
            finish(with: true)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                guard notification.object as? WKWebView === panel.webView else { return }
                evaluate()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { notification in
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == panelId else { return }
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved else { return }
                let focused = (self.tabManager?.selectedWorkspace?.browserPanel(for: panelId)).map(self.appDelegate.isWebViewFocused) ?? false
                finish(with: focused)
            }
        }
        Task { @MainActor in evaluate() }
    }

    private func setupFocusedInput(panel: BrowserPanel) {
        panel.webView.evaluateJavaScript(FocusSeedResult.seedScript) { [weak self] result, _ in
            guard let self else { return }
            let seed = FocusSeedResult(jsResult: result)
            let focused = seed.focused
            let inputId = seed.inputId
            let secondaryInputId = seed.secondaryInputId
            let secondaryCenterX = seed.secondaryCenterX
            let secondaryCenterY = seed.secondaryCenterY
            let activeId = seed.activeId
            let trackerInstalled = seed.trackerInstalled
            let trackedStateId = seed.trackedStateId
            let readyState = seed.readyState
            var secondaryClickOffsetX = -1.0
            var secondaryClickOffsetY = -1.0
            if let window = panel.webView.window {
                let webFrame = panel.webView.convert(panel.webView.bounds, to: nil)
                let contentHeight = Double(window.contentView?.bounds.height ?? 0)
                if let offset = FocusSeedClickOffset(
                    webFrame: webFrame,
                    contentHeight: contentHeight,
                    windowHeight: Double(window.frame.height),
                    secondaryCenterX: secondaryCenterX,
                    secondaryCenterY: secondaryCenterY
                ) {
                    secondaryClickOffsetX = offset.x
                    secondaryClickOffsetY = offset.y
                }
            }
            if focused,
               !inputId.isEmpty,
               !secondaryInputId.isEmpty,
               inputId == activeId,
               trackerInstalled,
               !trackedStateId.isEmpty,
               secondaryCenterX > 0,
               secondaryCenterX < 1,
               secondaryCenterY > 0,
               secondaryCenterY < 1,
               secondaryClickOffsetX > 0,
               secondaryClickOffsetY > 0 {
                self.writeData([
                    "webInputFocusSeeded": "true",
                    "webInputFocusElementId": inputId,
                    "webInputFocusSecondaryElementId": secondaryInputId,
                    "webInputFocusSecondaryCenterX": "\(secondaryCenterX)",
                    "webInputFocusSecondaryCenterY": "\(secondaryCenterY)",
                    "webInputFocusSecondaryClickOffsetX": "\(secondaryClickOffsetX)",
                    "webInputFocusSecondaryClickOffsetY": "\(secondaryClickOffsetY)",
                    "webInputFocusActiveElementId": activeId,
                    "webInputFocusTrackerInstalled": trackerInstalled ? "true" : "false",
                    "webInputFocusTrackedStateId": trackedStateId,
                    "webInputFocusReadyState": readyState
                ])
                return
            }
            self.writeData([
                "webInputFocusSeeded": "false",
                "setupError": "Timed out focusing page input for omnibar restore test"
            ])
        }
    }

    private func recordActiveElement(panelId: UUID, keyPrefix: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        let expectedInputId = keyPrefix == "addressBarExit" ? expectedInputId() : nil
        let capture: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.evaluateActiveElement(
                panel: panel,
                awaitingInputId: expectedInputId
            ) { probe in
                self.writeData(probe.recordedFields(keyPrefix: keyPrefix, panelId: panelId))
            }
        }

        if expectedInputId == nil {
            DispatchQueue.main.async {
                Task { @MainActor in capture() }
            }
        } else {
            Task { @MainActor in capture() }
        }
    }

    private func evaluateActiveElement(
        panel: BrowserPanel,
        awaitingInputId: String? = nil,
        completion: @escaping (ActiveElementProbeResult) -> Void
    ) {
        let expectedInputIdLiteral = awaitingInputId?.javaScriptStringLiteral ?? "null"
        let script = ActiveElementProbeResult.script(expectedInputIdLiteral: expectedInputIdLiteral)

        panel.webView.evaluateJavaScript(script) { result, _ in
            completion(ActiveElementProbeResult(jsResult: result))
        }
    }

    private func expectedInputId() -> String? {
        guard let path = environment["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return UITestKeyValueCaptureFile(path: path).load()["webInputFocusElementId"]
    }

    /// Live navigation hook: records a goto-split focus move.
    func recordMoveIfNeeded(direction: NavigationDirection) {
        guard isRecordingEnabled() else { return }
        guard let tabManager, let workspace = tabManager.selectedWorkspace else { return }

        var updates = findStateSnapshot(for: workspace)
        updates["lastMoveDirection"] = direction.directionLabel
        writeData(updates)
    }

    /// Live navigation hook: records a goto-split pane split.
    func recordSplitIfNeeded(direction: SplitDirection) {
        guard isRecordingEnabled() else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        var updates = findStateSnapshot(for: workspace)
        updates["lastSplitDirection"] = direction.directionLabel
        updates["paneCountAfterSplit"] = String(workspace.bonsplitController.allPaneIds.count)
        writeData(updates)
    }

    /// Live navigation hook: records the settled state after a split-zoom
    /// toggle.
    func recordZoomIfNeeded(tabManager: TabManager? = nil) {
        guard isRecordingEnabled() else { return }
        guard let workspace = (tabManager ?? self.tabManager)?.selectedWorkspace else { return }

        func snapshot(for workspace: Workspace) -> ([String: String], Bool) {
            let browserPanel = workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
            let otherTerminal = workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
            let browserSnapshot = browserPanel.flatMap { BrowserWindowPortalRegistry.debugSnapshot(for: $0.webView) }

            let focusedPanelIsTerminal: Bool = {
                guard let focusedPanelId = workspace.focusedPanelId else { return false }
                return workspace.terminalPanel(for: focusedPanelId) != nil
            }()

            let zoomSnapshot = GotoSplitZoomSnapshot(
                isSplitZoomed: workspace.bonsplitController.isSplitZoomed,
                zoomedPaneId: workspace.bonsplitController.zoomedPaneId?.description,
                focusedPanelIsTerminal: focusedPanelIsTerminal,
                browserPanelId: browserPanel?.id.uuidString,
                browserPortal: browserSnapshot.map {
                    GotoSplitZoomSnapshot.PortalGeometry(
                        isHidden: $0.containerHidden,
                        isVisibleInUI: $0.visibleInUI,
                        frameInWindow: $0.frameInWindow
                    )
                },
                otherTerminalPanelId: otherTerminal?.id.uuidString,
                otherTerminalPortal: otherTerminal.map {
                    GotoSplitZoomSnapshot.PortalGeometry(
                        isHidden: $0.hostedView.isHidden,
                        isVisibleInUI: $0.hostedView.debugPortalVisibleInUI,
                        frameInWindow: $0.hostedView.debugPortalFrameInWindow
                    )
                }
            )

            var updates = self.findStateSnapshot(for: workspace)
            updates.merge(zoomSnapshot.captureFields) { _, new in new }
            return (updates, zoomSnapshot.settled)
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
            self.writeData(updates)
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

    private func writeData(_ updates: [String: String]) {
        guard let path = dataPath() else { return }
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }
}
#endif
