#if DEBUG
import AppKit
import Bonsplit
import CmuxTestSupport
import Foundation

/// Records bonsplit tab-drag UI-test state for the
/// `CMUX_UI_TEST_BONSPLIT_TAB_DRAG_*` XCUITest scenario.
///
/// This is the app-target conformer of ``UITestRecording`` for the
/// bonsplit-tab-drag scenario: it owns the live `AppDelegate` it reads
/// workspace/pane/sidebar state from, which is why it cannot live in
/// `CmuxTestSupport` (a lower package cannot reference `AppDelegate`).
/// ``installIfNeeded()`` is gated by `CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP`
/// and is a no-op in production; it carries its own one-shot guard so the
/// composition root can call it unconditionally during launch.
///
/// The recorder waits for a ready main window, seeds two titled surfaces
/// (and optional action buttons / sidebar visibility) per the scenario's
/// environment, writes the initial fixture, then polls every 100 ms with a
/// `DispatchSource` timer recording the tracked pane's tab titles. The
/// capture file path, JSON shape, and key set are byte-identical to the
/// legacy `AppDelegate` implementation this was lifted from.
@MainActor
final class BonsplitTabDragUITestRecorder: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSetup = false
    private var recorderTimer: DispatchSourceTimer?

    /// Creates a recorder bound to `appDelegate`, reading scenario gates from
    /// `environment`.
    ///
    /// - Parameters:
    ///   - appDelegate: The live app delegate whose windows/workspaces the
    ///     recorder reads.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    deinit {
        recorderTimer?.cancel()
    }

    func installIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        let env = environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
        guard appDelegate.tabManager != nil else { return }
        let startWithHiddenSidebar = env["CMUX_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] == "1"
        let showRightSidebar = env["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] == "1"

        let deadline = Date().addingTimeInterval(20.0)
        func mainWindowContextForUITest() -> (window: NSWindow, context: AppDelegate.RegisteredMainWindow)? {
            for window in NSApp.windows {
                guard let raw = window.identifier?.rawValue else { continue }
                guard raw == "cmux.main" || raw.hasPrefix("cmux.main.") else { continue }
                guard let context = self.appDelegate.contextForMainTerminalWindow(window),
                      self.appDelegate.fileExplorerState(for: context) != nil else {
                    continue
                }
                return (window, context)
            }
            return nil
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeBonsplitTabDragUITestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard let (mainWindow, context) = mainWindowContextForUITest() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }

            let screenFrame = mainWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            if let screenFrame {
                let targetSize: NSSize
                if let rawSize = env["CMUX_UI_TEST_BONSPLIT_WINDOW_SIZE"] {
                    let parts = rawSize
                        .split(separator: "x", maxSplits: 1)
                        .compactMap { Double(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if parts.count == 2 {
                        targetSize = NSSize(
                            width: min(max(320, parts[0]), screenFrame.width - 80),
                            height: min(max(240, parts[1]), screenFrame.height - 80)
                        )
                    } else {
                        targetSize = NSSize(width: min(960, screenFrame.width - 80), height: min(720, screenFrame.height - 80))
                    }
                } else {
                    targetSize = NSSize(width: min(960, screenFrame.width - 80), height: min(720, screenFrame.height - 80))
                }
                let targetOrigin = NSPoint(
                    x: screenFrame.minX + 40,
                    y: screenFrame.maxY - 40 - targetSize.height
                )
                let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
                if !mainWindow.frame.equalTo(targetFrame) {
                    mainWindow.setFrame(targetFrame, display: true)
                }
            }
            let tabManager = context.tabManager
            guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first,
                  let alphaPanelId = workspace.focusedPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Missing initial workspace or panel"])
                return
            }

            let workspaceTitle = "UITest Workspace"
            let alphaTitle = "UITest Alpha"
            let betaTitle = "UITest Beta"
            tabManager.setCustomTitle(tabId: workspace.id, title: workspaceTitle)
            workspace.setPanelCustomTitle(panelId: alphaPanelId, title: alphaTitle)
            tabManager.newSurface()

            guard let betaPanelId = workspace.focusedPanelId, betaPanelId != alphaPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Failed to create second surface"])
                return
            }

            workspace.setPanelCustomTitle(panelId: betaPanelId, title: betaTitle)
            if let rawActionButtonCount = env["CMUX_UI_TEST_BONSPLIT_ACTION_BUTTON_COUNT"],
               let requestedActionButtonCount = Int(rawActionButtonCount),
               requestedActionButtonCount > 0 {
                guard let cmuxConfigStore = self.appDelegate.configStore(for: context) else {
                    self.writeBonsplitTabDragUITestData(["setupError": "Missing cmux config store"])
                    return
                }
                let actionButtonCount = min(requestedActionButtonCount, 32)
                let buttons = (1...actionButtonCount).map { index in
                    let actionTitle = String(
                        format: String(
                            localized: "uiTest.bonsplit.action.title",
                            defaultValue: "UITest Action %lld"
                        ),
                        Int64(index)
                    )
                    return CmuxSurfaceTabBarButton.actionReference(
                        "cmux-ui-test-action-\(index)",
                        title: actionTitle,
                        icon: .symbol("circle.fill"),
                        tooltip: actionTitle
                    )
                }
                workspace.applySurfaceTabBarButtons(
                    buttons,
                    sourcePath: nil,
                    globalConfigPath: cmuxConfigStore.globalConfigPath,
                    terminalCommandSourcePaths: [:],
                    workspaceCommands: [:]
                )
            }
            if startWithHiddenSidebar {
                self.appDelegate.sidebarState(for: context).isVisible = false
            }
            if showRightSidebar {
                guard let fileExplorerState = self.appDelegate.fileExplorerState(for: context) else {
                    self.writeBonsplitTabDragUITestData(["setupError": "Missing right sidebar state"])
                    return
                }
                fileExplorerState.mode = .files
                fileExplorerState.setVisible(true)
            }
            self.writeBonsplitTabDragUITestData([
                "ready": "1",
                "sidebarVisible": startWithHiddenSidebar ? "0" : "1",
                "rightSidebarVisible": self.appDelegate.fileExplorerState(for: context)?.isVisible == true ? "1" : "0",
                "workspaceId": workspace.id.uuidString,
                "workspaceTitle": workspaceTitle,
                "alphaTitle": alphaTitle,
                "betaTitle": betaTitle,
                "alphaPanelId": alphaPanelId.uuidString,
                "betaPanelId": betaPanelId.uuidString,
            ])
            self.startBonsplitTabDragUITestRecorder(
                workspaceId: workspace.id,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func bonsplitTabDragUITestDataPath() -> String? {
        let env = environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func startBonsplitTabDragUITestRecorder(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        recorderTimer?.cancel()
        recorderTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordBonsplitTabDragUITestState(
                workspaceId: workspaceId,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }
        recorderTimer = timer
        timer.resume()
    }

    private func recordBonsplitTabDragUITestState(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        guard let tabManager = appDelegate.tabManager else { return }
        guard let workspace = (tabManager.tabs.first { $0.id == workspaceId } ?? tabManager.selectedWorkspace ?? tabManager.tabs.first) else {
            return
        }

        let trackedPaneId = workspace.paneId(forPanelId: alphaPanelId)
            ?? workspace.paneId(forPanelId: betaPanelId)
            ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let trackedPaneId else { return }

        let titles: [String] = workspace.bonsplitController.tabs(inPane: trackedPaneId).compactMap { tab in
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { return nil }
            return workspace.panelTitle(panelId: panelId)
        }
        let selectedTitle = workspace.bonsplitController.selectedTab(inPane: trackedPaneId)
            .flatMap { workspace.panelIdFromSurfaceId($0.id) }
            .flatMap { workspace.panelTitle(panelId: $0) } ?? ""

        writeBonsplitTabDragUITestData([
            "trackedPaneId": trackedPaneId.description,
            "trackedPaneTabTitles": titles.joined(separator: "|"),
            "trackedPaneTabCount": String(titles.count),
            "trackedPaneSelectedTitle": selectedTitle,
        ])
    }

    private func writeBonsplitTabDragUITestData(_ updates: [String: String]) {
        guard let path = bonsplitTabDragUITestDataPath() else { return }
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }
}
#endif
