import XCTest
import Foundation

final class CloseWorkspaceCmdDUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdDConfirmsCloseWhenClosingLastWorkspaceClosesWindow() {
        let app = XCUIApplication()
        // Force a confirmation alert when closing the current workspace so we can validate Cmd+D.
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        app.activate()

        // Close current workspace. With a single workspace/window, this will close the window after confirmation.
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForCloseWorkspaceAlert(app: app, timeout: 5.0))

        // Cmd+D should accept the destructive close and close the window.
        app.typeKey("d", modifierFlags: [.command])

        XCTAssertTrue(
            waitForNoWindowsOrAppNotRunningForeground(app: app, timeout: 6.0),
            "Expected Cmd+D to confirm close and close the last window"
        )
    }

    func testCmdDConfirmsCloseWhenClosingLastTabClosesWindow() {
        let app = XCUIApplication()
        // Closing the last tab should also present a confirmation and accept Cmd+D when it would close the window.
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        app.activate()

        // Close current tab (Cmd+W). With a single workspace and a single tab, this will close the window after confirmation.
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(waitForCloseTabAlert(app: app, timeout: 5.0))

        // Cmd+D should accept the destructive close and close the window.
        app.typeKey("d", modifierFlags: [.command])

        XCTAssertTrue(
            waitForNoWindowsOrAppNotRunningForeground(app: app, timeout: 6.0),
            "Expected Cmd+D to confirm close and close the last window"
        )
    }

    func testCmdNOpensNewWindowWhenNoWindowsOpen() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        app.activate()

        // Close the only window.
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForCloseWorkspaceAlert(app: app, timeout: 5.0))
        app.typeKey("d", modifierFlags: [.command])

        XCTAssertTrue(
            waitForWindowCount(app: app, toBe: 0, timeout: 6.0),
            "Expected last window to close"
        )

        // Cmd+N should create a new window when there are no windows.
        app.activate()
        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(
            waitForWindowCount(app: app, atLeast: 1, timeout: 6.0),
            "Expected Cmd+N to open a new window when no windows are open"
        )
    }

    func testChildExitInHorizontalSplitClosesOnlyExitedPane() {
        let attempts = 8
        for attempt in 1...attempts {
            let app = XCUIApplication()
            let dataPath = "/tmp/cmux-ui-test-child-exit-split-\(UUID().uuidString).json"
            try? FileManager.default.removeItem(atPath: dataPath)

            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] = dataPath
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] = "lr"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] = "1"
            app.launch()
            app.activate()
            defer { app.terminate() }

            XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: 12.0), "Attempt \(attempt): expected child-exit test data at \(dataPath)")
            guard let data = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 12.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for done=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            if let setupError = data["setupError"], !setupError.isEmpty {
                XCTFail("Attempt \(attempt): setup failed: \(setupError)")
                return
            }

            let workspaceCountAfter = Int(data["workspaceCountAfter"] ?? "") ?? -1
            let panelCountAfter = Int(data["panelCountAfter"] ?? "") ?? -1
            let closedWorkspace = (data["closedWorkspace"] ?? "") == "1"
            let timedOut = (data["timedOut"] ?? "") == "1"

            XCTAssertFalse(timedOut, "Attempt \(attempt): timed out waiting for child-exit close. data=\(data)")
            XCTAssertEqual(workspaceCountAfter, 1, "Attempt \(attempt): expected workspace to remain open. data=\(data)")
            XCTAssertEqual(panelCountAfter, 1, "Attempt \(attempt): expected only exited pane to close. data=\(data)")
            XCTAssertFalse(closedWorkspace, "Attempt \(attempt): expected workspace/window to stay open. data=\(data)")
        }
    }

    func testCtrlDFromKeyboardInHorizontalSplitClosesOnlyFocusedPane() {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-child-exit-keyboard-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] = dataPath
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: 12.0), "Expected keyboard child-exit setup data at \(dataPath)")
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 12.0) else {
            XCTFail("Timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let rightPanelId = ready["rightPanelId"] ?? ""
        XCTAssertEqual(ready["focusedPanelBefore"], rightPanelId, "Expected right split to be the focused panel before Ctrl+D. data=\(ready)")
        XCTAssertEqual(ready["firstResponderPanelBefore"], rightPanelId, "Expected AppKit first responder to match right split before Ctrl+D. data=\(ready)")

        // Exercise the real keyboard path (same path as user typing Ctrl+D), not an in-process helper.
        app.activate()
        app.typeKey("d", modifierFlags: [.control])

        guard let done = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 10.0) else {
            XCTFail("Timed out waiting for done=1 after Ctrl+D. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        let workspaceCountAfter = Int(done["workspaceCountAfter"] ?? "") ?? -1
        let panelCountAfter = Int(done["panelCountAfter"] ?? "") ?? -1
        let closedWorkspace = (done["closedWorkspace"] ?? "") == "1"
        let timedOut = (done["timedOut"] ?? "") == "1"
        let focusedPanelAfter = done["focusedPanelAfter"] ?? ""
        let firstResponderPanelAfter = done["firstResponderPanelAfter"] ?? ""

        XCTAssertFalse(timedOut, "Keyboard Ctrl+D test timed out. data=\(done)")
        XCTAssertFalse(closedWorkspace, "Ctrl+D should not close workspace/window when another pane remains. data=\(done)")
        XCTAssertEqual(workspaceCountAfter, 1, "Expected workspace to remain open after Ctrl+D in split. data=\(done)")
        XCTAssertEqual(panelCountAfter, 1, "Expected only exited pane to close after Ctrl+D in split. data=\(done)")
        if !focusedPanelAfter.isEmpty || !firstResponderPanelAfter.isEmpty {
            XCTAssertEqual(
                firstResponderPanelAfter,
                focusedPanelAfter,
                "Expected first responder and focused panel to converge after Ctrl+D. data=\(done)"
            )
        }
    }

    func testCtrlDFromKeyboardInThreePaneLayoutClosesOnlyFocusedPane() {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-child-exit-keyboard-tree-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] = "lr_left_vertical"
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] = "2"
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: 12.0), "Expected keyboard child-exit setup data at \(dataPath)")
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 12.0) else {
            XCTFail("Timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let rightPanelId = ready["rightPanelId"] ?? ""
        XCTAssertEqual(ready["focusedPanelBefore"], rightPanelId, "Expected right split to be focused before Ctrl+D. data=\(ready)")
        XCTAssertEqual(ready["firstResponderPanelBefore"], rightPanelId, "Expected first responder to match right split before Ctrl+D. data=\(ready)")
        guard let done = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 10.0) else {
            XCTFail("Timed out waiting for done=1 after Ctrl+D. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        let workspaceCountAfter = Int(done["workspaceCountAfter"] ?? "") ?? -1
        let panelCountAfter = Int(done["panelCountAfter"] ?? "") ?? -1
        let closedWorkspace = (done["closedWorkspace"] ?? "") == "1"
        let timedOut = (done["timedOut"] ?? "") == "1"
        let focusedPanelAfter = done["focusedPanelAfter"] ?? ""
        let firstResponderPanelAfter = done["firstResponderPanelAfter"] ?? ""

        XCTAssertFalse(timedOut, "Keyboard Ctrl+D test timed out. data=\(done)")
        XCTAssertFalse(closedWorkspace, "Ctrl+D should not close workspace/window when multiple panes remain. data=\(done)")
        XCTAssertEqual(workspaceCountAfter, 1, "Expected workspace to remain open after Ctrl+D in three-pane layout. data=\(done)")
        XCTAssertEqual(panelCountAfter, 2, "Expected only focused exited pane to close in three-pane layout. data=\(done)")
        if !focusedPanelAfter.isEmpty || !firstResponderPanelAfter.isEmpty {
            XCTAssertEqual(
                firstResponderPanelAfter,
                focusedPanelAfter,
                "Expected first responder and focused panel to converge after Ctrl+D in three-pane layout. data=\(done)"
            )
        }
    }

    func testCtrlDAfterClosingRightColumnIn2x2KeepsWorkspaceOpen() {
        // This regression can be timing-sensitive; run several fresh launches to catch
        // any single bad close routing/focus cycle.
        let attempts = 8
        for attempt in 1...attempts {
            let app = XCUIApplication()
            let dataPath = "/tmp/cmux-ui-test-child-exit-keyboard-2x2-\(UUID().uuidString).json"
            try? FileManager.default.removeItem(atPath: dataPath)
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] = dataPath
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] = "lrtd_close_right_then_exit_top_left"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] = "0"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] = "1"
            app.launch()
            app.activate()
            defer { app.terminate() }

            XCTAssertTrue(
                waitForAnyJSON(atPath: dataPath, timeout: 12.0),
                "Attempt \(attempt): expected keyboard child-exit setup data at \(dataPath)"
            )
            guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 12.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            if let setupError = ready["setupError"], !setupError.isEmpty {
                XCTFail("Attempt \(attempt): setup failed: \(setupError)")
                return
            }

            let panelCountBefore = Int(ready["panelCountBeforeCtrlD"] ?? "") ?? -1
            let exitPanelId = ready["exitPanelId"] ?? ""
            XCTAssertEqual(
                panelCountBefore,
                2,
                "Attempt \(attempt): expected two panels before Ctrl+D in 2x2-right-close repro. data=\(ready)"
            )
            XCTAssertEqual(
                ready["focusedPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected target exit pane to be focused before Ctrl+D. data=\(ready)"
            )
            XCTAssertEqual(
                ready["firstResponderPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected first responder to match target pane before Ctrl+D. data=\(ready)"
            )

            app.typeKey("d", modifierFlags: [.control])

            guard let done = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 10.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for done=1 after Ctrl+D. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            let workspaceCountAfter = Int(done["workspaceCountAfter"] ?? "") ?? -1
            let panelCountAfter = Int(done["panelCountAfter"] ?? "") ?? -1
            let closedWorkspace = (done["closedWorkspace"] ?? "") == "1"
            let timedOut = (done["timedOut"] ?? "") == "1"
            let focusedPanelAfter = done["focusedPanelAfter"] ?? ""
            let firstResponderPanelAfter = done["firstResponderPanelAfter"] ?? ""
            let triggerMode = done["autoTriggerMode"] ?? ""

            XCTAssertFalse(timedOut, "Attempt \(attempt): keyboard Ctrl+D 2x2-right-close timed out. data=\(done)")
            XCTAssertNotEqual(triggerMode, "runtime_close_callback", "Attempt \(attempt): expected real keyboard child-exit path, not runtime callback shortcut. data=\(done)")
            XCTAssertFalse(closedWorkspace, "Attempt \(attempt): Ctrl+D should not close workspace/window when another pane remains. data=\(done)")
            XCTAssertEqual(workspaceCountAfter, 1, "Attempt \(attempt): workspace should remain open after Ctrl+D. data=\(done)")
            XCTAssertEqual(panelCountAfter, 1, "Attempt \(attempt): only focused pane should close after Ctrl+D. data=\(done)")
            if !focusedPanelAfter.isEmpty || !firstResponderPanelAfter.isEmpty {
                XCTAssertEqual(
                    firstResponderPanelAfter,
                    focusedPanelAfter,
                    "Attempt \(attempt): expected focus indicator and first responder to converge after Ctrl+D. data=\(done)"
                )
            }
        }
    }

    func testCtrlDAfterClosingBottomRowIn2x2KeepsWorkspaceOpen() {
        let attempts = 8
        for attempt in 1...attempts {
            let app = XCUIApplication()
            let dataPath = "/tmp/cmux-ui-test-child-exit-keyboard-2x2-bottom-\(UUID().uuidString).json"
            try? FileManager.default.removeItem(atPath: dataPath)
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] = dataPath
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] = "tdlr_close_bottom_then_exit_top_left"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] = "0"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] = "1"
            app.launch()
            app.activate()
            defer { app.terminate() }

            XCTAssertTrue(
                waitForAnyJSON(atPath: dataPath, timeout: 12.0),
                "Attempt \(attempt): expected keyboard child-exit setup data at \(dataPath)"
            )
            guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 12.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            if let setupError = ready["setupError"], !setupError.isEmpty {
                XCTFail("Attempt \(attempt): setup failed: \(setupError)")
                return
            }

            let panelCountBefore = Int(ready["panelCountBeforeCtrlD"] ?? "") ?? -1
            let exitPanelId = ready["exitPanelId"] ?? ""
            XCTAssertEqual(
                panelCountBefore,
                2,
                "Attempt \(attempt): expected two panels before Ctrl+D in 2x2-bottom-close repro. data=\(ready)"
            )
            XCTAssertEqual(
                ready["focusedPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected target exit pane to be focused before Ctrl+D. data=\(ready)"
            )
            XCTAssertEqual(
                ready["firstResponderPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected first responder to match target pane before Ctrl+D. data=\(ready)"
            )

            app.typeKey("d", modifierFlags: [.control])

            guard let done = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 10.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for done=1 after Ctrl+D. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            let workspaceCountAfter = Int(done["workspaceCountAfter"] ?? "") ?? -1
            let panelCountAfter = Int(done["panelCountAfter"] ?? "") ?? -1
            let closedWorkspace = (done["closedWorkspace"] ?? "") == "1"
            let timedOut = (done["timedOut"] ?? "") == "1"
            let focusedPanelAfter = done["focusedPanelAfter"] ?? ""
            let firstResponderPanelAfter = done["firstResponderPanelAfter"] ?? ""
            let triggerMode = done["autoTriggerMode"] ?? ""

            XCTAssertFalse(timedOut, "Attempt \(attempt): keyboard Ctrl+D 2x2-bottom-close timed out. data=\(done)")
            XCTAssertNotEqual(triggerMode, "runtime_close_callback", "Attempt \(attempt): expected real keyboard child-exit path, not runtime callback shortcut. data=\(done)")
            XCTAssertFalse(closedWorkspace, "Attempt \(attempt): Ctrl+D should not close workspace/window when another pane remains. data=\(done)")
            XCTAssertEqual(workspaceCountAfter, 1, "Attempt \(attempt): workspace should remain open after Ctrl+D. data=\(done)")
            XCTAssertEqual(panelCountAfter, 1, "Attempt \(attempt): only focused pane should close after Ctrl+D. data=\(done)")
            if !focusedPanelAfter.isEmpty || !firstResponderPanelAfter.isEmpty {
                XCTAssertEqual(
                    firstResponderPanelAfter,
                    focusedPanelAfter,
                    "Attempt \(attempt): expected focus indicator and first responder to converge after Ctrl+D. data=\(done)"
                )
            }
        }
    }

    func testCtrlDFromRealKeyboardAfterClosingRightColumnIn2x2KeepsWorkspaceOpen() {
        let attempts = 8
        for attempt in 1...attempts {
            let app = XCUIApplication()
            let dataPath = "/tmp/cmux-ui-test-child-exit-keyboard-2x2-realkey-\(UUID().uuidString).json"
            try? FileManager.default.removeItem(atPath: dataPath)
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] = dataPath
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] = "lrtd_close_right_then_exit_top_left"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] = "0"
            app.launch()
            app.activate()
            defer { app.terminate() }

            XCTAssertTrue(
                waitForAnyJSON(atPath: dataPath, timeout: 12.0),
                "Attempt \(attempt): expected keyboard child-exit setup data at \(dataPath)"
            )
            guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 12.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            if let setupError = ready["setupError"], !setupError.isEmpty {
                XCTFail("Attempt \(attempt): setup failed: \(setupError)")
                return
            }

            let panelCountBefore = Int(ready["panelCountBeforeCtrlD"] ?? "") ?? -1
            let exitPanelId = ready["exitPanelId"] ?? ""
            XCTAssertEqual(
                panelCountBefore,
                2,
                "Attempt \(attempt): expected two panels before Ctrl+D in 2x2-right-close repro. data=\(ready)"
            )
            XCTAssertEqual(
                ready["focusedPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected target exit pane to be focused before Ctrl+D. data=\(ready)"
            )
            XCTAssertEqual(
                ready["firstResponderPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected first responder to match target pane before Ctrl+D. data=\(ready)"
            )

            app.typeKey("d", modifierFlags: [.control])

            guard let done = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 10.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for done=1 after real keyboard Ctrl+D. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            let workspaceCountAfter = Int(done["workspaceCountAfter"] ?? "") ?? -1
            let panelCountAfter = Int(done["panelCountAfter"] ?? "") ?? -1
            let closedWorkspace = (done["closedWorkspace"] ?? "") == "1"
            let timedOut = (done["timedOut"] ?? "") == "1"
            let focusedPanelAfter = done["focusedPanelAfter"] ?? ""
            let firstResponderPanelAfter = done["firstResponderPanelAfter"] ?? ""

            XCTAssertFalse(timedOut, "Attempt \(attempt): real keyboard Ctrl+D timed out. data=\(done)")
            XCTAssertFalse(closedWorkspace, "Attempt \(attempt): real keyboard Ctrl+D should not close workspace/window when another pane remains. data=\(done)")
            XCTAssertEqual(workspaceCountAfter, 1, "Attempt \(attempt): workspace should remain open after real keyboard Ctrl+D. data=\(done)")
            XCTAssertEqual(panelCountAfter, 1, "Attempt \(attempt): only focused pane should close after real keyboard Ctrl+D. data=\(done)")
            XCTAssertTrue(
                waitForWindowCount(app: app, atLeast: 1, timeout: 2.0),
                "Attempt \(attempt): app window should remain open after Ctrl+D closes one split. data=\(done)"
            )
            if let showChildExitedCount = Int(done["probeShowChildExitedCount"] ?? "") {
                XCTAssertEqual(showChildExitedCount, 1, "Attempt \(attempt): expected exactly one SHOW_CHILD_EXITED callback for one Ctrl+D. data=\(done)")
            }
            if let keyDownCount = Int(done["probeKeyDownCount"] ?? "") {
                XCTAssertEqual(keyDownCount, 1, "Attempt \(attempt): expected exactly one keyDown for one Ctrl+D keypress. data=\(done)")
            }
            if !focusedPanelAfter.isEmpty || !firstResponderPanelAfter.isEmpty {
                XCTAssertEqual(
                    firstResponderPanelAfter,
                    focusedPanelAfter,
                    "Attempt \(attempt): expected focus indicator and first responder to converge after real keyboard Ctrl+D. data=\(done)"
                )
            }
        }
    }

    func testCtrlDFromRealKeyboardInHorizontalSplitKeepsWindowOpen() {
        let attempts = 12
        for attempt in 1...attempts {
            let app = XCUIApplication()
            let dataPath = "/tmp/cmux-ui-test-child-exit-keyboard-lr-realkey-\(UUID().uuidString).json"
            try? FileManager.default.removeItem(atPath: dataPath)
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"] = dataPath
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] = "lr"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] = "0"
            app.launch()
            app.activate()
            defer { app.terminate() }

            XCTAssertTrue(
                waitForAnyJSON(atPath: dataPath, timeout: 12.0),
                "Attempt \(attempt): expected keyboard child-exit setup data at \(dataPath)"
            )
            guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 12.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            if let setupError = ready["setupError"], !setupError.isEmpty {
                XCTFail("Attempt \(attempt): setup failed: \(setupError)")
                return
            }

            let panelCountBefore = Int(ready["panelCountBeforeCtrlD"] ?? "") ?? -1
            let exitPanelId = ready["exitPanelId"] ?? ""
            XCTAssertEqual(
                panelCountBefore,
                2,
                "Attempt \(attempt): expected two panels before Ctrl+D in left/right repro. data=\(ready)"
            )
            XCTAssertEqual(
                ready["focusedPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected target exit pane to be focused before Ctrl+D. data=\(ready)"
            )
            XCTAssertEqual(
                ready["firstResponderPanelBefore"],
                exitPanelId,
                "Attempt \(attempt): expected first responder to match target pane before Ctrl+D. data=\(ready)"
            )

            app.typeKey("d", modifierFlags: [.control])

            guard let done = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 10.0) else {
                XCTFail("Attempt \(attempt): timed out waiting for done=1 after real keyboard Ctrl+D. data=\(loadJSON(atPath: dataPath) ?? [:])")
                return
            }

            let workspaceCountAfter = Int(done["workspaceCountAfter"] ?? "") ?? -1
            let panelCountAfter = Int(done["panelCountAfter"] ?? "") ?? -1
            let closedWorkspace = (done["closedWorkspace"] ?? "") == "1"
            let timedOut = (done["timedOut"] ?? "") == "1"
            let focusedPanelAfter = done["focusedPanelAfter"] ?? ""
            let firstResponderPanelAfter = done["firstResponderPanelAfter"] ?? ""

            XCTAssertFalse(timedOut, "Attempt \(attempt): real keyboard Ctrl+D timed out. data=\(done)")
            XCTAssertFalse(closedWorkspace, "Attempt \(attempt): real keyboard Ctrl+D should not close workspace/window when another pane remains. data=\(done)")
            XCTAssertEqual(workspaceCountAfter, 1, "Attempt \(attempt): workspace should remain open after real keyboard Ctrl+D. data=\(done)")
            XCTAssertEqual(panelCountAfter, 1, "Attempt \(attempt): only focused pane should close after real keyboard Ctrl+D. data=\(done)")
            XCTAssertTrue(
                waitForWindowCount(app: app, atLeast: 1, timeout: 2.0),
                "Attempt \(attempt): app window should remain open after Ctrl+D closes one split. data=\(done)"
            )
            if let showChildExitedCount = Int(done["probeShowChildExitedCount"] ?? "") {
                XCTAssertEqual(showChildExitedCount, 1, "Attempt \(attempt): expected exactly one SHOW_CHILD_EXITED callback for one Ctrl+D. data=\(done)")
            }
            if let keyDownCount = Int(done["probeKeyDownCount"] ?? "") {
                XCTAssertEqual(keyDownCount, 1, "Attempt \(attempt): expected exactly one keyDown for one Ctrl+D keypress. data=\(done)")
            }
            if !focusedPanelAfter.isEmpty || !firstResponderPanelAfter.isEmpty {
                XCTAssertEqual(
                    firstResponderPanelAfter,
                    focusedPanelAfter,
                    "Attempt \(attempt): expected focus indicator and first responder to converge after real keyboard Ctrl+D. data=\(done)"
                )
            }
        }
    }

    private func waitForCloseWorkspaceAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.dialogs.containing(.staticText, identifier: "Close workspace?").firstMatch.exists { return true }
            if app.alerts.containing(.staticText, identifier: "Close workspace?").firstMatch.exists { return true }
            if app.staticTexts["Close workspace?"].exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func waitForCloseTabAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.dialogs.containing(.staticText, identifier: "Close tab?").firstMatch.exists { return true }
            if app.alerts.containing(.staticText, identifier: "Close tab?").firstMatch.exists { return true }
            if app.staticTexts["Close tab?"].exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func waitForWindowCount(app: XCUIApplication, toBe count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return app.windows.count == count
    }

    private func waitForWindowCount(app: XCUIApplication, atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return app.windows.count >= count
    }

    private func waitForNoWindowsOrAppNotRunningForeground(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state != .runningForeground { return true }
            if app.windows.count == 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return app.state != .runningForeground || app.windows.count == 0
    }

    private func waitForAnyJSON(atPath path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadJSON(atPath: path) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path) != nil
    }

    private func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), data[key] == expected {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path), data[key] == expected {
            return data
        }
        return nil
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

}
