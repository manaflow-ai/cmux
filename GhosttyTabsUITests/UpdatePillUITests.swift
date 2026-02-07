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

        let pill = app.descendants(matching: .any)["UpdatePill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForLabel(pill, label: "Update Available: 9.9.9", timeout: 5.0))
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

        let pill = app.descendants(matching: .any)["UpdatePill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForLabel(pill, label: "No Updates Available", timeout: 5.0))
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

        let pill = app.descendants(matching: .any)["UpdatePill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForLabel(pill, label: "Update Available: 9.9.9", timeout: 5.0))
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-update-available")
    }

    func testCheckForUpdatesUsesMockFeedWithNoUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let timingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-timing-\(UUID().uuidString).json")
        let app = launchAppWithMockFeed(mode: "none", version: "9.9.9", timingPath: timingPath)

        let pill = app.descendants(matching: .any)["UpdatePill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5.0))
        XCTAssertTrue(waitForLabel(pill, label: "No Updates Available", timeout: 5.0))
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-no-updates")
    }

    private func waitForLabel(_ element: XCUIElement, label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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
