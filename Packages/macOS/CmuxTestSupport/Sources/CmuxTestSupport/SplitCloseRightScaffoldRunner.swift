#if DEBUG
public import Foundation

/// Drives the DEBUG split-then-close-right XCUITest harness: builds a 2x2 grid,
/// closes the two right panes through the Close-Tab path, then converges the
/// remaining layout over a few main-actor turns while writing capture fields the
/// out-of-process XCUITest reads back.
///
/// This is the lifted orchestration of TabManager's legacy
/// `runSplitCloseRightUITest`. All live workspace / Bonsplit / Ghostty / `NSApp`
/// reads and mutations are delegated to ``SplitCloseRightScaffoldDriving``, which
/// the app target conforms; the runner owns the harness *sequence* (the build
/// order, the close order, the settle predicate via
/// ``SplitCloseRightStateCollector``, and the capture writes). The visual-repro
/// branch forwards to the driver, which keeps the CVDisplayLink IOSurface
/// timeline app-side as sanctioned `#if DEBUG` scaffolding.
///
/// Faithfulness: the build sequence, the `setupError` / capture keys, the
/// `DispatchQueue.main.asyncAfter(0.2)` startup hop, the eight-attempt
/// reconcile loop, and the `finalAttempt` field reproduce the legacy body
/// exactly, so the gated behavior and the values handed to the XCUITest are
/// unchanged.
///
/// Isolation: `@MainActor`, matching the legacy body and the driver seam.
@MainActor
public struct SplitCloseRightScaffoldRunner {
    private let driver: any SplitCloseRightScaffoldDriving
    private let collector = SplitCloseRightStateCollector()

    /// Creates a runner bound to a live driver.
    ///
    /// - Parameter driver: The app-side conformer supplying the live actions.
    public init(driver: any SplitCloseRightScaffoldDriving) {
        self.driver = driver
    }

    /// Schedules the harness exactly as the legacy body did: a 0.2s startup hop
    /// onto the main queue, then the gated build/close/settle sequence.
    ///
    /// - Parameter config: The parsed, clamped split-close-right configuration.
    public func run(config: UITestSplitScaffoldPlan.SplitCloseRightConfig) {
        // Match the legacy `[weak self]` startup hop: if the driver (the live
        // TabManager) is gone by the time the timer or inner Task fires, bail.
        weak var weakDriver = driver
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard weakDriver != nil else { return }
            Task { @MainActor in
                guard let driver = weakDriver else { return }
                await SplitCloseRightScaffoldRunner(driver: driver).execute(config: config)
            }
        }
    }

    private func execute(config: UITestSplitScaffoldPlan.SplitCloseRightConfig) async {
        let capture = UITestKeyValueCaptureFile(path: config.path)

        let setup = await driver.prepareSplitCloseRight()
        let topLeftPanelId: UUID
        switch setup {
        case .failed(let captureFields):
            capture.merge(captureFields)
            return
        case .ready(let panelId, let captureFields):
            capture.merge(captureFields)
            topLeftPanelId = panelId
        }

        if config.visualMode {
            // Visual repro mode: repeat the split/close sequence many times and
            // sample the IOSurface timeline. The CVDisplayLink capture stays
            // app-side; the runner only records the gating fields and forwards.
            capture.merge([
                "visualMode": "1",
                "visualIterations": String(config.visualIterations),
                "visualDone": "0"
            ])

            await driver.runVisualRepro(topLeftPanelId: topLeftPanelId, config: config)

            capture.merge(["visualDone": "1"])
            return
        }

        // Layout goal: 2x2 grid (2 top, 2 bottom), then close both right panels.
        // Order matters: split down first, then split right in each row (matches
        // UI shortcut repro).
        guard let bottomLeft = driver.splitDown(from: topLeftPanelId) else {
            capture.merge(["setupError": "Failed to create bottom-left split"])
            return
        }
        guard let bottomRight = driver.splitRight(from: bottomLeft) else {
            capture.merge(["setupError": "Failed to create bottom-right split"])
            return
        }
        driver.focusPanel(topLeftPanelId)
        guard let topRight = driver.splitRight(from: topLeftPanelId) else {
            capture.merge(["setupError": "Failed to create top-right split"])
            return
        }

        capture.merge([
            "tabId": driver.workspaceIdString,
            "topLeftPanelId": topLeftPanelId.uuidString,
            "bottomLeftPanelId": bottomLeft.uuidString,
            "topRightPanelId": topRight.uuidString,
            "bottomRightPanelId": bottomRight.uuidString,
            "createdPaneCount": String(driver.paneCount),
            "createdPanelCount": String(driver.panelCount)
        ])

        driver.resetEmptyPanelAppearCount()

        // Close the two right panes via the same path as the Close Tab shortcut.
        driver.focusPanel(topRight)
        driver.closePanel(topRight)
        driver.focusPanel(bottomRight)
        driver.closePanel(bottomRight)

        // Capture final state after Bonsplit/AppKit/Ghostty geometry
        // reconciliation. We avoid sleep-based timing and converge over a few
        // main-actor turns.
        var finalState = collectState()
        for attempt in 1...8 {
            driver.reconcileVisibleTerminalGeometry()
            await Task.yield()
            finalState = collectState()
            var payload = finalState.data
            payload["finalAttempt"] = String(attempt)
            capture.merge(payload)
            if finalState.settled {
                break
            }
        }
    }

    private func collectState() -> SplitCloseRightStateCollector.Result {
        collector.collect(
            paneSnapshots: driver.paneSnapshots(),
            bonsplitTabCount: driver.bonsplitTabCount,
            panelCount: driver.panelCount,
            emptyPanelAppearCount: driver.emptyPanelAppearCount
        )
    }
}
#endif
