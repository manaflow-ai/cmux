#if DEBUG
import Foundation

/// Drives the DEBUG child-exit *keyboard* XCUITest harness: builds one of the
/// configured pane layouts, sends `exec cat` to the panel under test, waits for
/// it to be ready, records the pre-trigger state, then hands the post-trigger
/// resolution (synthetic Ctrl+D delivery, panel-count / workspace-alive
/// observation, and timeout) to the driver. The capture file lets the
/// out-of-process XCUITest read the close outcome and focus/first-responder
/// transitions back.
///
/// This is the lifted orchestration of TabManager's legacy
/// `runChildExitKeyboardUITest`. All live workspace / Bonsplit / Ghostty reads
/// and mutations are delegated to ``ChildExitScaffoldDriving``, which the app
/// target conforms; the runner owns the harness *setup sequence* (the 200ms
/// startup hop, the four layout build orders, the readiness gating, and the
/// `ready` capture write). The post-`ready` resolution machinery stays app-side
/// behind ``ChildExitScaffoldDriving/runChildExitKeyboardResolution(exitPanelId:capturePath:config:)``
/// because it owns the live Combine cancellable set, the `@Observable`
/// workspace-list observation, the `DispatchWorkItem` timeout, and the runtime
/// close callback, exactly as the split-close-right visual repro stays app-side.
///
/// Faithfulness: the 200ms startup sleep, every layout build order, the
/// `setupError` strings, the readiness gating and its capture fields, and the
/// `ready` payload reproduce the legacy body exactly.
///
/// Isolation: `@MainActor`, matching the legacy body and the driver seam.
@MainActor
public struct ChildExitKeyboardScaffoldRunner {
    private let driver: any ChildExitScaffoldDriving

    /// Creates a runner bound to a live driver.
    ///
    /// - Parameter driver: The app-side conformer supplying the live actions.
    public init(driver: any ChildExitScaffoldDriving) {
        self.driver = driver
    }

    /// Schedules the harness exactly as the legacy body did: a main-actor `Task`
    /// with a 200ms startup sleep, then the gated layout build and resolution.
    ///
    /// - Parameter config: The parsed, clamped child-exit keyboard configuration.
    public func run(config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig) {
        let driver = driver
        Task { @MainActor [weak driver] in
            guard let driver else { return }
            await ChildExitKeyboardScaffoldRunner(driver: driver).execute(config: config)
        }
    }

    private func execute(config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig) async {
        let useEarlyTrigger = config.useEarlyTrigger
        let layout = config.layout
        let expectedPanelsAfter = config.expectedPanelsAfter

        let capture = UITestKeyValueCaptureFile(path: config.path)

        try? await Task.sleep(nanoseconds: 200_000_000)

        guard driver.pinSelectedWorkspace() != nil else {
            capture.merge(["setupError": "Missing selected workspace", "done": "1"])
            return
        }
        guard let leftPanelId = driver.pinnedFocusedPanelId else {
            capture.merge(["setupError": "Missing initial focused panel", "done": "1"])
            return
        }
        guard let rightPanelId = driver.newRightSplit(from: leftPanelId) else {
            capture.merge(["setupError": "Failed to create right split", "done": "1"])
            return
        }

        var bottomLeftPanelId = ""
        let topRightPanelId = rightPanelId.uuidString
        var bottomRightPanelId = ""
        var exitPanelId = rightPanelId

        if layout == "lr_left_vertical" {
            guard let bottomLeft = driver.newDownSplit(from: leftPanelId) else {
                capture.merge(["setupError": "Failed to create bottom-left split", "done": "1"])
                return
            }
            bottomLeftPanelId = bottomLeft.uuidString
        } else if layout == "lrtd_close_right_then_exit_top_left" {
            guard let bottomLeft = driver.newDownSplit(from: leftPanelId) else {
                capture.merge(["setupError": "Failed to create bottom-left split", "done": "1"])
                return
            }
            guard let bottomRight = driver.newDownSplit(from: rightPanelId) else {
                capture.merge(["setupError": "Failed to create bottom-right split", "done": "1"])
                return
            }
            bottomLeftPanelId = bottomLeft.uuidString
            bottomRightPanelId = bottomRight.uuidString

            // Repro flow: with a 2x2 (left/right then top/down), close both right panes,
            // then trigger Ctrl+D in top-left.
            driver.focusPinnedPanel(rightPanelId)
            driver.closePinnedPanel(rightPanelId)
            driver.focusPinnedPanel(bottomRight)
            driver.closePinnedPanel(bottomRight)
            exitPanelId = leftPanelId

            let collapsed = await driver.waitForPanelCount(equals: 2, timeoutSeconds: 2.0)
            if !collapsed {
                capture.merge([
                    "setupError": "Expected 2 panels after closing right column, got \(driver.pinnedPanelCount)",
                    "done": "1",
                ])
                return
            }
        } else if layout == "tdlr_close_bottom_then_exit_top_left" {
            // Alternate repro flow:
            // 1) split top/down
            // 2) split left/right for each row (2x2)
            // 3) close both bottom panes
            // 4) trigger Ctrl+D in top-left
            guard let bottomLeft = driver.newDownSplit(from: leftPanelId) else {
                capture.merge(["setupError": "Failed to create bottom-left split", "done": "1"])
                return
            }
            guard let topRight = driver.newRightSplit(from: leftPanelId) else {
                capture.merge(["setupError": "Failed to create top-right split", "done": "1"])
                return
            }
            guard let bottomRight = driver.newRightSplit(from: bottomLeft) else {
                capture.merge(["setupError": "Failed to create bottom-right split", "done": "1"])
                return
            }
            bottomLeftPanelId = bottomLeft.uuidString
            bottomRightPanelId = bottomRight.uuidString

            // Close every pane except the top row; do it one-by-one and wait for model convergence.
            let keepPanels: Set<UUID> = [leftPanelId, topRight]
            for panelId in driver.pinnedPanelIds(excluding: leftPanelId) where !keepPanels.contains(panelId) {
                driver.focusPinnedPanel(panelId)
                driver.closePinnedPanel(panelId)
                let closed = await driver.waitForPanelRemoved(panelId, timeoutSeconds: 1.0)
                if !closed {
                    capture.merge([
                        "setupError": "Failed to close bottom pane \(panelId.uuidString)",
                        "done": "1",
                    ])
                    return
                }
            }
            exitPanelId = leftPanelId

            let collapsed = await driver.waitForPanelCount(equals: 2, timeoutSeconds: 2.0)
            if !collapsed {
                capture.merge([
                    "setupError": "Expected 2 panels after closing bottom row, got \(driver.pinnedPanelCount)",
                    "done": "1",
                ])
                return
            }
        }

        driver.focusPinnedPanel(exitPanelId)
        // Keep child-exit keyboard tests deterministic across user shell configs.
        // `exec cat` exits on a single Ctrl+D and avoids ignore-eof shell settings.
        driver.sendText(exitPanelId, "exec cat\r")

        var exitPanelAttachedBeforeCtrlD = false
        var exitPanelHasSurfaceBeforeCtrlD = false
        if !useEarlyTrigger {
            let readiness = await driver.waitForPanelReady(exitPanelId)
            exitPanelAttachedBeforeCtrlD = readiness.attached
            exitPanelHasSurfaceBeforeCtrlD = readiness.hasSurface
            if !(readiness.attached && readiness.hasSurface) {
                capture.merge([
                    "exitPanelAttachedBeforeCtrlD": readiness.attached ? "1" : "0",
                    "exitPanelHasSurfaceBeforeCtrlD": readiness.hasSurface ? "1" : "0",
                    "setupError": "Exit panel not ready for Ctrl+D (not attached or surface nil)",
                    "done": "1",
                ])
                return
            }
            driver.ensureFocusedTerminalFirstResponder()
        } else if let snapshot = driver.panelReadinessSnapshot(exitPanelId) {
            exitPanelAttachedBeforeCtrlD = snapshot.attached
            exitPanelHasSurfaceBeforeCtrlD = snapshot.hasSurface
        }

        let focusedPanelBefore = driver.pinnedFocusedPanelIdString
        let firstResponderPanelBefore = driver.pinnedFirstResponderTerminalPanelIdString

        capture.merge([
            "workspaceId": driver.pinnedWorkspaceIdString,
            "leftPanelId": leftPanelId.uuidString,
            "rightPanelId": rightPanelId.uuidString,
            "topRightPanelId": topRightPanelId,
            "bottomLeftPanelId": bottomLeftPanelId,
            "bottomRightPanelId": bottomRightPanelId,
            "exitPanelId": exitPanelId.uuidString,
            "panelCountBeforeCtrlD": String(driver.pinnedPanelCount),
            "layout": layout,
            "expectedPanelsAfter": String(expectedPanelsAfter),
            "focusedPanelBefore": focusedPanelBefore,
            "firstResponderPanelBefore": firstResponderPanelBefore,
            "exitPanelAttachedBeforeCtrlD": exitPanelAttachedBeforeCtrlD ? "1" : "0",
            "exitPanelHasSurfaceBeforeCtrlD": exitPanelHasSurfaceBeforeCtrlD ? "1" : "0",
            "ready": "1",
            "done": "0",
        ])

        // The post-`ready` resolution (observers, timeout, auto-trigger, and the
        // runtime close callback) owns live Combine / observation / DispatchWorkItem
        // state that cannot cross the package boundary, so it stays app-side.
        driver.runChildExitKeyboardResolution(
            exitPanelId: exitPanelId,
            capturePath: config.path,
            config: config
        )
    }
}
#endif
