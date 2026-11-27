#if DEBUG
import AppKit
import CmuxTestSupport
import Foundation

/// Debug-only app-host bridge for the cross-process goto-split UI tests.
///
/// XCUITest cannot construct or inspect the app's in-process pane model, so this
/// support stays isolated under `Sources/Debug/UITests` and is excluded from
/// non-Debug builds.
@MainActor
struct GotoSplitCycleUITestSupport {
    private let sink: UITestCaptureSink

    init(sink: UITestCaptureSink = UITestCaptureSink()) {
        self.sink = sink
    }

    func setupThreePaneTerminalLayout(
        tabManager: TabManager,
        previousShortcutDisplay: String,
        nextShortcutDisplay: String
    ) {
        guard let tab = tabManager.addWorkspaceIfActive() else {
            writeData(["setupError": "Failed to create workspace"])
            return
        }
        guard let initialPanelId = tab.focusedPanelId else {
            writeData(["setupError": "Missing initial panel id"])
            return
        }

        guard tabManager.createSplit(
            tabId: tab.id, surfaceId: initialPanelId, direction: .right
        ) != nil else {
            writeData(["setupError": "Failed to create horizontal split"])
            return
        }

        tab.focusPanel(initialPanelId)
        guard tabManager.createSplit(
            tabId: tab.id, surfaceId: initialPanelId, direction: .down
        ) != nil else {
            writeData(["setupError": "Failed to create vertical split"])
            return
        }

        var observer: NSObjectProtocol?
        var resolved = false

        func signalSetupComplete(notification: Notification) {
            guard !resolved else { return }
            if let notifiedTabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
               notifiedTabId != tab.id {
                return
            }
            guard let focusedPanelId = tab.focusedPanelId,
                  let terminalPanel = tab.terminalPanel(for: focusedPanelId),
                  let window = terminalPanel.hostedView.window,
                  let firstResponder = window.firstResponder,
                  terminalPanel.hostedView.responderMatchesPreferredKeyboardFocus(firstResponder) else {
                return
            }

            if let observer { NotificationCenter.default.removeObserver(observer) }
            resolved = true

            let allPaneIds = tab.spatiallyOrderedPaneIds.map(\.uuidString)
            writeData([
                "paneCount": String(allPaneIds.count),
                "allPaneIds": allPaneIds.joined(separator: ","),
                "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                "ghosttyGotoSplitPreviousShortcut": previousShortcutDisplay,
                "ghosttyGotoSplitNextShortcut": nextShortcutDisplay,
                "setupComplete": "true",
            ])
        }

        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                signalSetupComplete(notification: notification)
            }
        }

        tab.focusPanel(initialPanelId)
    }

    func recordCycleMoveIfNeeded(
        tabManager: TabManager?,
        tabId: UUID,
        forward: Bool
    ) {
        guard isRecordingEnabled() else { return }
        guard let tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else { return }

        var updates = stateSnapshot(for: workspace)
        updates["lastMoveDirection"] = forward ? "next" : "previous"
        writeData(updates)
    }

    private func isRecordingEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" || env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1"
    }

    private func stateSnapshot(for workspace: Workspace) -> [String: String] {
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
            currentResponder
                .cmuxStrictOwningGhosttyView()?
                .terminalSurface?.id.uuidString ?? ""

        updates.merge(cmuxFindResponderSnapshot()) { _, new in new }
        return updates
    }

    private func writeData(_ updates: [String: String]) {
        _ = sink.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_GOTO_SPLIT_PATH") { payload in
            for (key, value) in updates {
                payload[key] = value
            }
        }
    }
}
#endif
