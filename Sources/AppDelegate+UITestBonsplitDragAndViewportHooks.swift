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



// MARK: - UITest hooks: bonsplit tab drag and terminal viewport recorders (DEBUG)
extension AppDelegate {
#if DEBUG
    func setupBonsplitTabDragUITestIfNeeded() {
        guard !didSetupBonsplitTabDragUITest else { return }
        didSetupBonsplitTabDragUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }
        let startWithHiddenSidebar = env["CMUX_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] == "1"
        let showRightSidebar = env["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] == "1"

        let deadline = Date().addingTimeInterval(20.0)
        func mainWindowContextForUITest() -> (window: NSWindow, context: MainWindowContext)? {
            for window in NSApp.windows {
                guard let raw = window.identifier?.rawValue else { continue }
                guard raw == "cmux.main" || raw.hasPrefix("cmux.main.") else { continue }
                guard let context = self.contextForMainTerminalWindow(window),
                      context.fileExplorerState != nil else {
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
                guard let cmuxConfigStore = context.cmuxConfigStore else {
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
                context.sidebarState.isVisible = false
            }
            if showRightSidebar {
                guard let fileExplorerState = context.fileExplorerState else {
                    self.writeBonsplitTabDragUITestData(["setupError": "Missing right sidebar state"])
                    return
                }
                fileExplorerState.mode = .files
                fileExplorerState.setVisible(true)
            }
            self.writeBonsplitTabDragUITestData([
                "ready": "1",
                "sidebarVisible": startWithHiddenSidebar ? "0" : "1",
                "rightSidebarVisible": context.fileExplorerState?.isVisible == true ? "1" : "0",
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

    func setupTerminalViewportUITestIfNeeded() {
        guard !didSetupTerminalViewportUITest else { return }
        let env = ProcessInfo.processInfo.environment
        guard TerminalViewportUITestRecorder.isEnabled(environment: env) else { return }
        didSetupTerminalViewportUITest = true

        terminalViewportUITestRecorder?.stop()
        terminalViewportUITestRecorder = TerminalViewportUITestRecorder(environment: env) { [weak self] in
            guard let self else { return [] }
            return Array(self.mainWindowContexts.values)
        }
        terminalViewportUITestRecorder?.start()
    }

    private func bonsplitTabDragUITestDataPath() -> String? {
        let env = ProcessInfo.processInfo.environment
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
        bonsplitTabDragUITestRecorder?.cancel()
        bonsplitTabDragUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordBonsplitTabDragUITestState(
                workspaceId: workspaceId,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }
        bonsplitTabDragUITestRecorder = timer
        timer.resume()
    }

    private func recordBonsplitTabDragUITestState(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        guard let tabManager else { return }
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
        var payload = loadBonsplitTabDragUITestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadBonsplitTabDragUITestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif
}
