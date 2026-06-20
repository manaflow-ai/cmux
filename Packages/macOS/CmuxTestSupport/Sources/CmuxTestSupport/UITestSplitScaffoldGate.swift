public import Foundation

/// Builds a ``UITestSplitScaffoldPlan`` from a process-environment snapshot.
///
/// This is the pure decision half of the DEBUG split / child-exit UI-test
/// scaffolding: it reads only `CMUX_UI_TEST_*` environment variables and
/// decides which harnesses are enabled and with what parsed configuration. It
/// performs no I/O and touches no live app object, so it is unit-testable in
/// isolation. The app target feeds it `ProcessInfo.processInfo.environment` and
/// then drives the enabled scaffolds through ``UITestScaffoldRunning``.
///
/// Faithfulness: every default, trimming step, and integer clamp reproduces the
/// legacy inline parsing in `TabManager`'s `setup*UITestIfNeeded` methods
/// byte-for-byte, so the gated behavior and the values handed to each harness
/// are unchanged.
///
/// Isolation: a stateless `Sendable` struct; `plan(from:)` is a pure transform.
public struct UITestSplitScaffoldGate: Sendable {
    /// Creates a gate. The gate holds no state; the instance exists only so the
    /// parsing lives on a real type rather than as a free function.
    public init() {}

    /// Parses `environment` into the typed scaffold plan.
    ///
    /// - Parameter environment: A process-environment snapshot, normally
    ///   `ProcessInfo.processInfo.environment`.
    /// - Returns: The plan describing which scaffolds are enabled. A scaffold
    ///   whose gate variable is unset (or whose required capture path is
    ///   missing/empty) is reported as disabled.
    public func plan(from environment: [String: String]) -> UITestSplitScaffoldPlan {
        UITestSplitScaffoldPlan(
            installsFocusShortcuts: environment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] == "1",
            splitCloseRight: splitCloseRightConfig(from: environment),
            childExitSplit: childExitSplitConfig(from: environment),
            childExitKeyboard: childExitKeyboardConfig(from: environment)
        )
    }

    private func splitCloseRightConfig(
        from env: [String: String]
    ) -> UITestSplitScaffoldPlan.SplitCloseRightConfig? {
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] == "1" else { return nil }
        guard let path = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"], !path.isEmpty else { return nil }
        let visualMode = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1"
        let shotsDir = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visualIterations = Int(
            (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] ?? "20")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 20
        let burstFrames = Int(
            (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] ?? "6")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 6
        let closeDelayMs = Int(
            (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] ?? "70")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 70
        let pattern = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] ?? "close_right")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UITestSplitScaffoldPlan.SplitCloseRightConfig(
            path: path,
            visualMode: visualMode,
            shotsDir: shotsDir,
            visualIterations: visualIterations,
            burstFrames: burstFrames,
            closeDelayMs: closeDelayMs,
            pattern: pattern
        )
    }

    private func childExitSplitConfig(
        from env: [String: String]
    ) -> UITestSplitScaffoldPlan.ChildExitSplitConfig? {
        guard env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP"] == "1" else { return nil }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH"], !path.isEmpty else { return nil }
        let requestedIterations = Int(env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_ITERATIONS"] ?? "1") ?? 1
        let iterations = max(1, min(requestedIterations, 20))
        return UITestSplitScaffoldPlan.ChildExitSplitConfig(
            path: path,
            requestedIterations: requestedIterations,
            iterations: iterations
        )
    }

    private func childExitKeyboardConfig(
        from env: [String: String]
    ) -> UITestSplitScaffoldPlan.ChildExitKeyboardConfig? {
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1" else { return nil }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"], !path.isEmpty else { return nil }
        let autoTrigger = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] == "1"
        let strictKeyOnly = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] == "1"
        let triggerMode = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE"] ?? "shell_input")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useEarlyCtrlShiftTrigger = triggerMode == "early_ctrl_shift_d"
        let useEarlyCtrlDTrigger = triggerMode == "early_ctrl_d"
        let useEarlyTrigger = useEarlyCtrlShiftTrigger || useEarlyCtrlDTrigger
        let triggerUsesShift = triggerMode == "ctrl_shift_d" || useEarlyCtrlShiftTrigger
        let layout = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] ?? "lr")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPanelsAfter = max(
            1,
            Int(
                (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] ?? "1")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 1
        )
        return UITestSplitScaffoldPlan.ChildExitKeyboardConfig(
            path: path,
            autoTrigger: autoTrigger,
            strictKeyOnly: strictKeyOnly,
            triggerMode: triggerMode,
            useEarlyCtrlShiftTrigger: useEarlyCtrlShiftTrigger,
            useEarlyCtrlDTrigger: useEarlyCtrlDTrigger,
            useEarlyTrigger: useEarlyTrigger,
            triggerUsesShift: triggerUsesShift,
            layout: layout,
            expectedPanelsAfter: expectedPanelsAfter
        )
    }
}
