#if DEBUG
import Foundation
import Testing
@testable import CmuxTestSupport

/// A scriptable ``ChildExitScaffoldDriving`` fake: it serves canned panel ids
/// and readiness, records the call order, and lets the tests assert the lifted
/// runner orchestration and capture-file output without any live app state.
@MainActor
private final class FakeChildExitDriver: ChildExitScaffoldDriving {
    var hasSelectedWorkspace = true
    var workspaceCount = 1
    var pinnedWorkspaceIsAlive = true
    var pinnedPanelCount = 1
    var pinnedFocusedPanelId: UUID?
    var pinnedFirstPanelId: UUID?
    var pinnedWorkspaceIdString = "WS"
    var pinnedFocusedPanelIdString = "FP"
    var pinnedFirstResponderTerminalPanelIdString = "FR"

    /// New ids handed back from split creation, popped in order.
    var splitIds: [UUID] = []
    private(set) var calls: [String] = []
    private(set) var resolutionRan = false
    private(set) var resolutionExitPanelId: UUID?

    private let pinnedId = UUID()

    func pinSelectedWorkspace() -> UUID? {
        calls.append("pin")
        return hasSelectedWorkspace ? pinnedId : nil
    }

    func pinnedPanelIds(excluding panelId: UUID) -> [UUID] { [] }

    func closePinnedPanel(_ panelId: UUID) { calls.append("close:\(panelId)") }

    private func nextSplit() -> UUID? {
        guard !splitIds.isEmpty else { return nil }
        return splitIds.removeFirst()
    }

    func newRightSplit(from panelId: UUID) -> UUID? {
        calls.append("right:\(panelId)")
        return nextSplit()
    }

    func newDownSplit(from panelId: UUID) -> UUID? {
        calls.append("down:\(panelId)")
        return nextSplit()
    }

    func focusPinnedPanel(_ panelId: UUID) { calls.append("focus:\(panelId)") }

    func sendText(_ panelId: UUID, _ text: String) { calls.append("send:\(panelId):\(text)") }

    func waitForPanelCount(equals count: Int, timeoutSeconds: TimeInterval) async -> Bool { true }

    func waitForPanelRemoved(_ panelId: UUID, timeoutSeconds: TimeInterval) async -> Bool { true }

    func waitForPanelAttachedWithSurface(_ panelId: UUID, timeoutSeconds: TimeInterval) async -> Bool { true }

    func waitForPanelCountToCollapse() async -> Bool { true }

    func waitForPanelReady(_ panelId: UUID) async -> ChildExitPanelReadiness {
        ChildExitPanelReadiness(attached: true, hasSurface: true, firstResponder: true)
    }

    func panelReadinessSnapshot(_ panelId: UUID) -> ChildExitPanelReadiness? {
        ChildExitPanelReadiness(attached: true, hasSurface: true, firstResponder: false)
    }

    func ensureFocusedTerminalFirstResponder() { calls.append("ensureFR") }

    func runChildExitKeyboardResolution(
        exitPanelId: UUID,
        capturePath: String,
        config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig
    ) {
        resolutionRan = true
        resolutionExitPanelId = exitPanelId
    }
}

@Suite("ChildExitScaffoldRunner")
@MainActor
struct ChildExitScaffoldRunnerTests {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("childexit-\(UUID().uuidString).json")
            .path
    }

    private func read(_ path: String) -> [String: String] {
        UITestKeyValueCaptureFile(path: path).load()
    }

    @Test func splitMissingWorkspaceWritesSetupError() async {
        let driver = FakeChildExitDriver()
        driver.hasSelectedWorkspace = false
        let path = tempPath()
        await runSplitExecute(
            driver: driver,
            config: .init(path: path, requestedIterations: 1, iterations: 1)
        )
        let out = read(path)
        #expect(out["setupError"] == "Missing selected workspace")
        #expect(out["done"] == "1")
    }

    @Test func splitOneIterationWritesProgressAndSummary() async {
        let driver = FakeChildExitDriver()
        let left = UUID()
        let right = UUID()
        driver.pinnedFocusedPanelId = left
        driver.splitIds = [right]
        let path = tempPath()
        await runSplitExecute(
            driver: driver,
            config: .init(path: path, requestedIterations: 1, iterations: 1)
        )
        let out = read(path)
        #expect(out["iterations"] == "1")
        #expect(out["leftPanelId"] == left.uuidString)
        #expect(out["rightPanelId"] == right.uuidString)
        #expect(out["completedIterations"] == "1")
        #expect(out["timedOut"] == "0")
        #expect(out["done"] == "1")
        // The right split is created, focused, sent `exit\r`, then awaited closed.
        #expect(driver.calls.contains("right:\(left)"))
        #expect(driver.calls.contains("focus:\(right)"))
        #expect(driver.calls.contains("send:\(right):exit\r"))
    }

    @Test func keyboardLrLeftVerticalBuildsBottomLeftAndHandsOffResolution() async {
        let driver = FakeChildExitDriver()
        let left = UUID()
        let right = UUID()
        let bottomLeft = UUID()
        driver.pinnedFocusedPanelId = left
        driver.splitIds = [right, bottomLeft]
        let path = tempPath()
        await runKeyboardExecute(
            driver: driver,
            config: keyboardConfig(path: path, layout: "lr_left_vertical")
        )
        let out = read(path)
        #expect(out["ready"] == "1")
        #expect(out["leftPanelId"] == left.uuidString)
        #expect(out["rightPanelId"] == right.uuidString)
        #expect(out["bottomLeftPanelId"] == bottomLeft.uuidString)
        #expect(out["exitPanelId"] == right.uuidString)
        #expect(driver.resolutionRan)
        #expect(driver.resolutionExitPanelId == right)
        // The bottom-left split is a DOWN split from the left panel.
        #expect(driver.calls.contains("down:\(left)"))
    }

    @Test func keyboardLrtdClosesRightColumnAndExitsTopLeft() async {
        let driver = FakeChildExitDriver()
        let left = UUID()
        let right = UUID()
        let bottomLeft = UUID()
        let bottomRight = UUID()
        driver.pinnedFocusedPanelId = left
        driver.splitIds = [right, bottomLeft, bottomRight]
        let path = tempPath()
        await runKeyboardExecute(
            driver: driver,
            config: keyboardConfig(path: path, layout: "lrtd_close_right_then_exit_top_left")
        )
        let out = read(path)
        #expect(out["ready"] == "1")
        #expect(out["exitPanelId"] == left.uuidString)
        #expect(driver.calls.contains("close:\(right)"))
        #expect(driver.calls.contains("close:\(bottomRight)"))
        #expect(driver.resolutionExitPanelId == left)
    }

    @Test func keyboardMissingFocusedPanelWritesSetupError() async {
        let driver = FakeChildExitDriver()
        driver.pinnedFocusedPanelId = nil
        let path = tempPath()
        await runKeyboardExecute(
            driver: driver,
            config: keyboardConfig(path: path, layout: "lr")
        )
        let out = read(path)
        #expect(out["setupError"] == "Missing initial focused panel")
        #expect(out["done"] == "1")
        #expect(!driver.resolutionRan)
    }

    // MARK: - Helpers

    private func keyboardConfig(
        path: String,
        layout: String
    ) -> UITestSplitScaffoldPlan.ChildExitKeyboardConfig {
        .init(
            path: path,
            autoTrigger: false,
            strictKeyOnly: false,
            triggerMode: "key",
            useEarlyCtrlShiftTrigger: false,
            useEarlyCtrlDTrigger: false,
            useEarlyTrigger: false,
            triggerUsesShift: false,
            layout: layout,
            expectedPanelsAfter: 1
        )
    }

    /// Drives the split runner's gated body synchronously by awaiting `run`'s
    /// scheduled `Task` through a yield (the runner schedules onto the main
    /// actor, and these tests are `@MainActor`).
    private func runSplitExecute(
        driver: FakeChildExitDriver,
        config: UITestSplitScaffoldPlan.ChildExitSplitConfig
    ) async {
        ChildExitSplitScaffoldRunner(driver: driver).run(config: config)
        await drainMainActor()
    }

    private func runKeyboardExecute(
        driver: FakeChildExitDriver,
        config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig
    ) async {
        ChildExitKeyboardScaffoldRunner(driver: driver).run(config: config)
        await drainMainActor()
    }

    /// Yields enough times to let the runner's scheduled `Task` (which includes a
    /// 200ms startup sleep) run to completion before the test inspects output.
    private func drainMainActor() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        for _ in 0..<50 { await Task.yield() }
    }
}
#endif
