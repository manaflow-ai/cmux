import XCTest
import Foundation

final class UpdatePillUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testUpdatePillShowsForAvailableUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "available"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        app.launch()
        app.activate()

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Available: 9.9.9")
        assertVisibleSize(pill)
        attachScreenshot(name: "update-available")
        // Element screenshots are flaky on the UTM VM (image creation fails intermittently).
        // Keep a stable attachment with element state instead.
        attachElementDebug(name: "update-available-pill", element: pill)
    }

    func testUpdatePillShowsForNoUpdateThenDismisses() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let timingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-timing-\(UUID().uuidString).json")
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "notFound"
        app.launchEnvironment["CMUX_UI_TEST_TIMING_PATH"] = timingPath.path
        app.launch()
        app.activate()

        let pill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "No Updates Available")
        assertVisibleSize(pill)
        attachScreenshot(name: "no-updates")
        attachElementDebug(name: "no-updates-pill", element: pill)

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: pill
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 7.0), .completed)

        let payload = loadTimingPayload(from: timingPath)
        let shownAt = payload["noUpdateShownAt"] ?? 0
        let hiddenAt = payload["noUpdateHiddenAt"] ?? 0
        XCTAssertGreaterThan(shownAt, 0)
        XCTAssertGreaterThan(hiddenAt, shownAt)
        XCTAssertGreaterThanOrEqual(hiddenAt - shownAt, 4.8)
    }

    func testCheckForUpdatesUsesMockFeedWithUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = launchAppWithMockFeed(mode: "available", version: "9.9.9")

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Available: 9.9.9")
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-update-available")
    }

    func testCheckForUpdatesUsesMockFeedWithNoUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let timingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-timing-\(UUID().uuidString).json")
        let app = launchAppWithMockFeed(mode: "none", version: "9.9.9", timingPath: timingPath)

        let pill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "No Updates Available")
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-no-updates")
    }

    func testNoSparklePermissionDialogIsShown() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()

        let app = XCUIApplication()
        // Make Sparkle re-request permission on startup, but we should auto-handle it with no UI.
        app.launchEnvironment["CMUX_UI_TEST_RESET_SPARKLE_PERMISSION"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        // Sparkle's default permission prompt is an NSAlert with these labels.
        XCTAssertFalse(app.staticTexts["Check for updates automatically?"].waitForExistence(timeout: 2.0))
        XCTAssertFalse(app.buttons["Don't Check"].exists)
        XCTAssertFalse(app.buttons["Check Automatically"].exists)
    }

    private func pillButton(app: XCUIApplication, expectedLabel: String) -> XCUIElement {
        // On macOS, SwiftUI accessibility identifiers are not always reliably surfaced for titlebar-style
        // UI across OS/Xcode versions. Prefer the pill's accessibility label, but keep an identifier
        // fallback for local runs.
        return app.buttons[expectedLabel]
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return app.windows.count >= count
    }

    private func assertVisibleSize(_ element: XCUIElement, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        var size = element.frame.size
        while Date() < deadline {
            size = element.frame.size
            if size.width > 20 && size.height > 10 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Expected UpdatePill to have visible size, got \(size)")
    }

    private func attachScreenshot(name: String, screenshot: XCUIScreenshot = XCUIScreen.main.screenshot()) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachElementDebug(name: String, element: XCUIElement) {
        let payload = """
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

    private func launchAppWithMockFeed(mode: String, version: String, timingPath: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FEED_URL"] = "https://cmuxterm.test/appcast.xml"
        app.launchEnvironment["CMUX_UI_TEST_FEED_MODE"] = mode
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = version
        app.launchEnvironment["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] = "1"
        if let timingPath {
            app.launchEnvironment["CMUX_UI_TEST_TIMING_PATH"] = timingPath.path
        }
        app.launch()
        app.activate()
        return app
    }

    private func loadTimingPayload(from url: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else {
            return [:]
        }
        return object
    }
}
