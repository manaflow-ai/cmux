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
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-child-exit-split-\(UUID().uuidString).json"
        let socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)

        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH"] = dataPath
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: 12.0), "Expected child-exit test data at \(dataPath)")
        guard let data = waitForJSONKey("done", equals: "1", atPath: dataPath, timeout: 20.0) else {
            XCTFail("Timed out waiting for done=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let workspaceCountAfter = Int(data["workspaceCountAfter"] ?? "") ?? -1
        let panelCountAfter = Int(data["panelCountAfter"] ?? "") ?? -1
        let closedWorkspace = (data["closedWorkspace"] ?? "") == "1"
        let timedOut = (data["timedOut"] ?? "") == "1"

        XCTAssertEqual(workspaceCountAfter, 1, "Expected workspace to remain open. data=\(data)")
        XCTAssertEqual(panelCountAfter, 1, "Expected only exited pane to close. data=\(data)")
        XCTAssertFalse(closedWorkspace, "Expected workspace/window to stay open. data=\(data)")
        XCTAssertFalse(timedOut, "Timed out waiting for exited pane to close. data=\(data)")
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
