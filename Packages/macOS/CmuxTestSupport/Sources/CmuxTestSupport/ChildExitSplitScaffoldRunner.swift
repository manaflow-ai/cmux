#if DEBUG
import Foundation

/// Drives the DEBUG child-exit *split* XCUITest harness: repeatedly resets the
/// selected workspace to 1x1, creates a right split, sends `exit` to the split,
/// waits for the pane to close, and records per-iteration progress to a capture
/// file the out-of-process XCUITest reads back.
///
/// This is the lifted orchestration of TabManager's legacy
/// `runChildExitSplitUITest`. All live workspace / Bonsplit / Ghostty reads and
/// mutations are delegated to ``ChildExitScaffoldDriving``, which the app target
/// conforms; the runner owns the harness *sequence* (the 200ms startup hop, the
/// `1...iterations` loop, the collapse / split / send-exit / wait order, and
/// every capture write).
///
/// Faithfulness: the 200ms startup sleep, the per-iteration guards and capture
/// keys, the `setupError` strings, the collapse / readiness / close waits and
/// their timeouts, and the final summary fields reproduce the legacy body
/// exactly, so the values handed to the XCUITest are unchanged. The driver pins
/// the workspace once (the legacy strong-`tab` capture) so `panelCountAfter`
/// still reflects the captured workspace even after it closes.
///
/// Isolation: `@MainActor`, matching the legacy body and the driver seam.
@MainActor
public struct ChildExitSplitScaffoldRunner {
    private let driver: any ChildExitScaffoldDriving

    /// Creates a runner bound to a live driver.
    ///
    /// - Parameter driver: The app-side conformer supplying the live actions.
    public init(driver: any ChildExitScaffoldDriving) {
        self.driver = driver
    }

    /// Schedules the harness exactly as the legacy body did: a main-actor `Task`
    /// with a 200ms startup sleep, then the gated build/exit loop.
    ///
    /// - Parameter config: The parsed, clamped child-exit split configuration.
    public func run(config: UITestSplitScaffoldPlan.ChildExitSplitConfig) {
        let driver = driver
        Task { @MainActor [weak driver] in
            guard let driver else { return }
            await ChildExitSplitScaffoldRunner(driver: driver).execute(config: config)
        }
    }

    private func execute(config: UITestSplitScaffoldPlan.ChildExitSplitConfig) async {
        let requestedIterations = config.requestedIterations
        let iterations = config.iterations

        let capture = UITestKeyValueCaptureFile(path: config.path)

        // Small delay so the initial window/panel has completed first layout.
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard driver.pinSelectedWorkspace() != nil else {
            capture.merge(["setupError": "Missing selected workspace", "done": "1"])
            return
        }
        capture.merge([
            "requestedIterations": String(requestedIterations),
            "iterations": String(iterations),
            "workspaceCountBefore": String(driver.workspaceCount),
            "panelCountBefore": String(driver.pinnedPanelCount),
            "done": "0",
        ])

        var completedIterations = 0
        var timedOut = false
        var closedWorkspace = false

        for i in 1...iterations {
            guard driver.pinnedWorkspaceIsAlive else {
                closedWorkspace = true
                break
            }

            guard let leftPanelId = driver.pinnedFocusedPanelId ?? driver.pinnedFirstPanelId else {
                capture.merge(["setupError": "Missing focused panel before iteration \(i)", "done": "1"])
                return
            }

            // Start each iteration from a deterministic 1x1 workspace.
            if driver.pinnedPanelCount > 1 {
                for panelId in driver.pinnedPanelIds(excluding: leftPanelId) {
                    driver.closePinnedPanel(panelId)
                }
                let collapsed = await driver.waitForPanelCount(equals: 1, timeoutSeconds: 2.0)
                if !collapsed {
                    capture.merge(["setupError": "Timed out collapsing workspace before iteration \(i)", "done": "1"])
                    return
                }
            }

            guard let rightPanelId = driver.newRightSplit(from: leftPanelId) else {
                capture.merge(["setupError": "Failed to create right split at iteration \(i)", "done": "1"])
                return
            }

            capture.merge([
                "iteration": String(i),
                "leftPanelId": leftPanelId.uuidString,
                "rightPanelId": rightPanelId.uuidString,
            ])

            driver.focusPinnedPanel(rightPanelId)
            // Wait for the split terminal surface to be attached before sending exit.
            // Without this, very early writes can be dropped during initial surface creation.
            _ = await driver.waitForPanelAttachedWithSurface(rightPanelId, timeoutSeconds: 2.0)
            // Use an explicit shell exit command for deterministic child-exit behavior across
            // startup timing variance; this still exercises the same SHOW_CHILD_EXITED path.
            driver.sendText(rightPanelId, "exit\r")

            // Wait for the right panel to close.
            let closed = await driver.waitForPanelCountToCollapse()

            if !closed {
                timedOut = true
                capture.merge(["timedOutIteration": String(i)])
                break
            }

            if !driver.pinnedWorkspaceIsAlive {
                closedWorkspace = true
                capture.merge(["closedWorkspaceIteration": String(i)])
                break
            }

            completedIterations = i
        }

        let workspaceStillOpen = driver.pinnedWorkspaceIsAlive
        let effectiveClosedWorkspace = closedWorkspace || !workspaceStillOpen

        capture.merge([
            "workspaceCountAfter": String(driver.workspaceCount),
            "panelCountAfter": String(driver.pinnedPanelCount),
            "workspaceStillOpen": workspaceStillOpen ? "1" : "0",
            "closedWorkspace": effectiveClosedWorkspace ? "1" : "0",
            "timedOut": timedOut ? "1" : "0",
            "completedIterations": String(completedIterations),
            "done": "1",
        ])
    }
}
#endif
