import XCTest
import Foundation

final class MenuKeyEquivalentRoutingUITests: XCTestCase {
    private var gotoSplitPath = ""
    private var keyequivPath = ""
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        gotoSplitPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
        keyequivPath = "/tmp/cmux-ui-test-keyequiv-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"

        try? FileManager.default.removeItem(atPath: gotoSplitPath)
        try? FileManager.default.removeItem(atPath: keyequivPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testCmdNWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["addTabInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(
            waitForKeyequivInt(key: "addTabInvocations", toBeAtLeast: baseline + 1, timeout: 5.0),
            "Expected Cmd+N to reach app menu and create a new tab even when WKWebView is first responder"
        )
    }

    func testCmdWWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["closePanelInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("w", modifierFlags: [.command])

        XCTAssertTrue(
            waitForKeyequivInt(key: "closePanelInvocations", toBeAtLeast: baseline + 1, timeout: 5.0),
            "Expected Cmd+W to reach app menu and close the focused panel even when WKWebView is first responder"
        )
    }

    private func launchWithBrowserSetup() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = gotoSplitPath
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = keyequivPath
        app.launch()
        app.activate()

        XCTAssertTrue(
            waitForGotoSplit(keys: ["browserPanelId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        if let setup = loadGotoSplit() {
            XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test setup")
        }

        return app
    }

    private func refocusWebView(app: XCUIApplication) {
        // Cmd+L focuses the omnibar (so WebKit is no longer first responder).
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar (WebKit not first responder)"
        )

        // Escape should leave the omnibar and focus WebKit again.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarExit"] == "true"
            },
            "Expected Escape to return focus to WebKit"
        )
    }

    private func waitForGotoSplit(keys: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadGotoSplit(), keys.allSatisfy({ data[$0] != nil }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadGotoSplit(), keys.allSatisfy({ data[$0] != nil }) {
            return true
        }
        return false
    }

    private func waitForGotoSplitMatch(timeout: TimeInterval, predicate: ([String: String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadGotoSplit(), predicate(data) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadGotoSplit(), predicate(data) {
            return true
        }
        return false
    }

    private func waitForKeyequivInt(key: String, toBeAtLeast expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = loadKeyequiv()[key].flatMap(Int.init) ?? 0
            if value >= expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let value = loadKeyequiv()[key].flatMap(Int.init) ?? 0
        return value >= expected
    }

    private func loadGotoSplit() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: gotoSplitPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func loadKeyequiv() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: keyequivPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}

