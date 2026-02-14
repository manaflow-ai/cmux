import XCTest
import Foundation

final class BrowserOmnibarSuggestionsUITests: XCTestCase {
    private var dataPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-omnibar-suggestions-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    func testOmnibarSuggestionsAlignToPillAndCtrlNP() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        // Keep suggestions deterministic for the keyboard-nav assertions.
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        app.launch()
        app.activate()

        // Focus omnibar.
        app.typeKey("l", modifierFlags: [.command])

        let pill = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarPill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        // Type a query that matches the seeded URL.
        omnibar.typeText("exam")

        // SwiftUI's accessibility typing for ScrollView can vary; match by identifier regardless of element type.
        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        // Frame checks (screen coordinates).
        let pillFrame = pill.frame
        let suggestionsFrame = suggestionsElement.frame
        attachElementDebug(name: "omnibar-pill", element: pill)
        attachElementDebug(name: "omnibar-suggestions", element: suggestionsElement)

        XCTAssertGreaterThan(pillFrame.width, 50)
        XCTAssertGreaterThan(suggestionsFrame.width, 50)

        let xTolerance: CGFloat = 3.0
        let wTolerance: CGFloat = 3.0

        XCTAssertLessThanOrEqual(abs(pillFrame.minX - suggestionsFrame.minX), xTolerance,
                                 "Expected suggestions minX to match omnibar minX.\nPill: \(pillFrame)\nSug: \(suggestionsFrame)")
        XCTAssertLessThanOrEqual(abs(pillFrame.width - suggestionsFrame.width), wTolerance,
                                 "Expected suggestions width to match omnibar width.\nPill: \(pillFrame)\nSug: \(suggestionsFrame)")

        // Ctrl+N should select the first history suggestion (2nd row) and Enter should navigate to the URL.
        app.typeKey("n", modifierFlags: [.control])

        // Wait for selection to move to row 1 (history) before committing.
        let row1 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.1").firstMatch
        XCTAssertTrue(row1.waitForExistence(timeout: 6.0))
        let selectDeadline = Date().addingTimeInterval(2.0)
        while Date() < selectDeadline {
            let v = (row1.value as? String) ?? ""
            if v.contains("selected") {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(((row1.value as? String) ?? "").contains("selected"), "Expected Ctrl+N to select row 1. value=\(String(describing: row1.value))")

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        // After committing the history suggestion, the omnibar should contain the URL.
        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            let value = (omnibar.value as? String) ?? ""
            if value.contains("example.com") {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Expected omnibar to navigate to example.com after Ctrl+N + Enter. value=\(String(describing: omnibar.value))")
    }

    func testOmnibarEscapeAndClickOutsideBehaveLikeChrome() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        // Keep suggestions deterministic.
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        app.launch()
        app.activate()

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        // Focus omnibar and navigate to example.com via history suggestion (same as the alignment test).
        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("exam")

        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        app.typeKey("n", modifierFlags: [.control])

        // Wait for selection to move to row 1 (history) before committing.
        let row1 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.1").firstMatch
        XCTAssertTrue(row1.waitForExistence(timeout: 6.0))
        let selectDeadline = Date().addingTimeInterval(2.0)
        while Date() < selectDeadline {
            let v = (row1.value as? String) ?? ""
            if v.contains("selected") {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(((row1.value as? String) ?? "").contains("selected"), "Expected Ctrl+N to select row 1. value=\(String(describing: row1.value))")

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            let value = (omnibar.value as? String) ?? ""
            if value.contains("example.com") {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(((omnibar.value as? String) ?? "").contains("example.com"))

        // Type a new query to open the popup, then Escape should revert to the current URL.
        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("meaning")
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let reverted = (omnibar.value as? String) ?? ""
        XCTAssertTrue(reverted.contains("example.com"), "Expected Escape to revert omnibar to current URL. value=\(reverted)")
        XCTAssertFalse(suggestionsElement.waitForExistence(timeout: 0.5), "Expected Escape to close suggestions popup")

        // Second Escape should blur to the web view: typing should not change the omnibar value.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let beforeTyping = (omnibar.value as? String) ?? ""
        app.typeText("zzz")
        let afterTyping = (omnibar.value as? String) ?? ""
        XCTAssertEqual(afterTyping, beforeTyping, "Expected typing after 2nd Escape to not modify omnibar (blurred)")

        // Click outside should also discard edits and blur.
        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("foo")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6.0))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()

        // Give SwiftUI focus a moment to settle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let afterClick = (omnibar.value as? String) ?? ""
        XCTAssertTrue(afterClick.contains("example.com"), "Expected click-outside to discard edits. value=\(afterClick)")

        let beforeOutsideTyping = (omnibar.value as? String) ?? ""
        app.typeText("bbb")
        let afterOutsideTyping = (omnibar.value as? String) ?? ""
        XCTAssertEqual(afterOutsideTyping, beforeOutsideTyping, "Expected typing after click-outside to not modify omnibar (blurred)")
    }

    private func seedBrowserHistoryForTest() {
        // Keep the test hermetic: write a deterministic history file in the app's support dir
        // so the omnibar always has at least one local suggestion row.
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            XCTFail("Missing Application Support directory")
            return
        }

        let bundleId = "com.cmuxterm.app.debug"
        let dir = appSupport.appendingPathComponent(bundleId, isDirectory: true)
        let url = dir.appendingPathComponent("browser_history.json", isDirectory: false)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create app support dir: \(error)")
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        let json = """
        [
          {
            "id": "\(UUID().uuidString)",
            "url": "https://example.com/",
            "title": "Example Domain",
            "lastVisited": \(now),
            "visitCount": 3
          }
        ]
        """
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write browser history seed file: \(error)")
        }
    }

    private func attachElementDebug(name: String, element: XCUIElement) {
        let payload = """
        identifier: \(element.identifier)
        label: \(element.label)
        exists: \(element.exists)
        hittable: \(element.isHittable)
        frame: \(element.frame)
        """
        let attachment = XCTAttachment(string: payload)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
