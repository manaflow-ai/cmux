import XCTest

/// The key row debate's mocks (on hold; Leo, 2026-11-22: "just debate this for a while, hold and
/// present"), drawn in the key row gallery (`-cmux-mobile-recovery-gallery keybar`,
/// `KeyRowDebateMocks`): asserts each mock is there and attaches a screenshot of each.
final class KeyRowDebateMocksUITests: XCTestCase {
    private static let mocks = ["A", "B", "C1", "C2", "C3", "C.run"]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMocks() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "keybar", "-cmux-mobile-no-restore",
                                "-cmux-mobile-gallery-appearance", "dark"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["recoveryGallery.keybar"].waitForExistence(timeout: 30),
                      "gallery\n\(app.debugDescription)")
        for id in Self.mocks {
            let mock = app.descendants(matching: .any)["keyRowMock.\(id)"]
            XCTAssertTrue(mock.waitForExistence(timeout: 10), "keyRowMock.\(id)\n\(app.debugDescription)")
            // Scroll the gallery until the mock is fully on screen (bounded).
            var swipes = 0
            while !app.windows.firstMatch.frame.contains(mock.frame), swipes < 12 {
                app.swipeUp(velocity: .slow)
                swipes += 1
            }
            let attachment = XCTAttachment(screenshot: mock.screenshot())
            attachment.name = "keyRowMock.\(id)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let full = XCTAttachment(screenshot: app.screenshot())
            full.name = "keyRowMock.\(id)-screen"
            full.lifetime = .keepAlways
            add(full)
        }
    }
}
