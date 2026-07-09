import Foundation
import Testing
@testable import CmuxTestSupport

@Suite("UITestSplitScaffoldGate")
struct UITestSplitScaffoldGateTests {
    private let gate = UITestSplitScaffoldGate()

    @Test func emptyEnvironmentEnablesNothing() {
        let plan = gate.plan(from: [:])
        #expect(plan.isEmpty)
        #expect(!plan.installsFocusShortcuts)
        #expect(plan.splitCloseRight == nil)
        #expect(plan.childExitSplit == nil)
        #expect(plan.childExitKeyboard == nil)
    }

    @Test func focusShortcutsGateOnExactlyOne() {
        #expect(gate.plan(from: ["CMUX_UI_TEST_FOCUS_SHORTCUTS": "1"]).installsFocusShortcuts)
        #expect(!gate.plan(from: ["CMUX_UI_TEST_FOCUS_SHORTCUTS": "0"]).installsFocusShortcuts)
        #expect(!gate.plan(from: ["CMUX_UI_TEST_FOCUS_SHORTCUTS": "true"]).installsFocusShortcuts)
    }

    @Test func splitCloseRightRequiresSetupAndNonEmptyPath() {
        #expect(gate.plan(from: ["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP": "1"]).splitCloseRight == nil)
        #expect(
            gate.plan(from: [
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP": "1",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH": "",
            ]).splitCloseRight == nil
        )
        #expect(
            gate.plan(from: [
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH": "/tmp/scr.json",
            ]).splitCloseRight == nil
        )
    }

    @Test func splitCloseRightDefaultsMatchLegacy() throws {
        let config = try #require(
            gate.plan(from: [
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP": "1",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH": "/tmp/scr.json",
            ]).splitCloseRight
        )
        #expect(config.path == "/tmp/scr.json")
        #expect(!config.visualMode)
        #expect(config.shotsDir == "")
        #expect(config.visualIterations == 20)
        #expect(config.burstFrames == 6)
        #expect(config.closeDelayMs == 70)
        #expect(config.pattern == "close_right")
    }

    @Test func splitCloseRightParsesAndTrimsValues() throws {
        let config = try #require(
            gate.plan(from: [
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP": "1",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH": "/tmp/scr.json",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL": "1",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR": "  /tmp/shots  ",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS": " 12 ",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES": "30",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS": "120",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN": " close_bottom ",
            ]).splitCloseRight
        )
        #expect(config.visualMode)
        #expect(config.shotsDir == "/tmp/shots")
        #expect(config.visualIterations == 12)
        #expect(config.burstFrames == 30)
        #expect(config.closeDelayMs == 120)
        #expect(config.pattern == "close_bottom")
    }

    @Test func splitCloseRightNonNumericFallsBackToDefault() throws {
        let config = try #require(
            gate.plan(from: [
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP": "1",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH": "/tmp/scr.json",
                "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS": "abc",
            ]).splitCloseRight
        )
        #expect(config.visualIterations == 20)
    }

    @Test func childExitSplitClampsIterations() throws {
        func iterations(_ raw: String) throws -> (requested: Int, clamped: Int) {
            let config = try #require(
                gate.plan(from: [
                    "CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH": "/tmp/ces.json",
                    "CMUX_UI_TEST_CHILD_EXIT_SPLIT_ITERATIONS": raw,
                ]).childExitSplit
            )
            return (config.requestedIterations, config.iterations)
        }
        #expect(try iterations("5") == (5, 5))
        #expect(try iterations("0") == (0, 1))
        #expect(try iterations("100") == (100, 20))
        #expect(try iterations("nope") == (1, 1))
    }

    @Test func childExitSplitDefaultsToOneIteration() throws {
        let config = try #require(
            gate.plan(from: [
                "CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP": "1",
                "CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH": "/tmp/ces.json",
            ]).childExitSplit
        )
        #expect(config.requestedIterations == 1)
        #expect(config.iterations == 1)
    }

    @Test func childExitKeyboardDerivesTriggerFlags() throws {
        func config(_ mode: String) throws -> UITestSplitScaffoldPlan.ChildExitKeyboardConfig {
            try #require(
                gate.plan(from: [
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": "/tmp/cek.json",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE": mode,
                ]).childExitKeyboard
            )
        }

        let shellInput = try config("shell_input")
        #expect(shellInput.triggerMode == "shell_input")
        #expect(!shellInput.useEarlyTrigger)
        #expect(!shellInput.triggerUsesShift)

        let earlyCtrlShift = try config("early_ctrl_shift_d")
        #expect(earlyCtrlShift.useEarlyCtrlShiftTrigger)
        #expect(earlyCtrlShift.useEarlyTrigger)
        #expect(earlyCtrlShift.triggerUsesShift)

        let earlyCtrlD = try config("early_ctrl_d")
        #expect(earlyCtrlD.useEarlyCtrlDTrigger)
        #expect(earlyCtrlD.useEarlyTrigger)
        #expect(!earlyCtrlD.triggerUsesShift)

        let ctrlShift = try config("ctrl_shift_d")
        #expect(!ctrlShift.useEarlyTrigger)
        #expect(ctrlShift.triggerUsesShift)
    }

    @Test func childExitKeyboardDefaultsAndExpectedPanelsFloor() throws {
        let defaults = try #require(
            gate.plan(from: [
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": "/tmp/cek.json",
            ]).childExitKeyboard
        )
        #expect(defaults.triggerMode == "shell_input")
        #expect(defaults.layout == "lr")
        #expect(defaults.expectedPanelsAfter == 1)
        #expect(!defaults.autoTrigger)
        #expect(!defaults.strictKeyOnly)

        func expectedPanels(_ raw: String) throws -> Int {
            try #require(
                gate.plan(from: [
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": "/tmp/cek.json",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": raw,
                ]).childExitKeyboard
            ).expectedPanelsAfter
        }
        #expect(try expectedPanels("3") == 3)
        #expect(try expectedPanels("0") == 1)
        #expect(try expectedPanels("nope") == 1)
    }

    @Test func allScaffoldsCanBeEnabledTogether() {
        let plan = gate.plan(from: [
            "CMUX_UI_TEST_FOCUS_SHORTCUTS": "1",
            "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP": "1",
            "CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH": "/tmp/scr.json",
            "CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP": "1",
            "CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH": "/tmp/ces.json",
            "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
            "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": "/tmp/cek.json",
        ])
        #expect(!plan.isEmpty)
        #expect(plan.installsFocusShortcuts)
        #expect(plan.splitCloseRight != nil)
        #expect(plan.childExitSplit != nil)
        #expect(plan.childExitKeyboard != nil)
    }
}
